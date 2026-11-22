import importlib.util
import os
import tempfile
import unittest
from pathlib import Path


spec = importlib.util.spec_from_file_location("caddy_config", Path(__file__).with_name("configure-caddy.py"))
caddy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(caddy)

EXISTING = """{
  email admin@example.com
  on_demand_tls {
    ask http://localhost:3000/tls-check
  }
}

torah.example.com {
  reverse_proxy http://127.0.0.1:8100
}

*.pds.example.com, pds.example.com {
  tls {
    on_demand
  }
  handle /.well-known/did.json {
    rewrite * /did.json
    root * /etc/caddy
    file_server
  }
  handle {
    reverse_proxy http://localhost:3000
  }
}

# This unrelated site must survive installer reruns exactly as written.
other.example.com {
  header X-Example "literal } { and # stay untouched"
  reverse_proxy 127.0.0.1:8766
}
"""


class CaddyPreservationTests(unittest.TestCase):
    def test_bind_change_preserves_every_existing_route_byte(self):
        rendered, additions = caddy.render(EXISTING, "10.42.1.135", web="torah.example.com", pds="pds.example.com")
        self.assertEqual(rendered.replace("  default_bind 10.42.1.135\n", "", 1), EXISTING)
        self.assertEqual(additions, [])

    def test_recovered_config_is_idempotent(self):
        first, _ = caddy.render(EXISTING, "10.42.1.135", appview="appview.example.com")
        second, additions = caddy.render(first, "10.42.1.135", appview="appview.example.com", web="torah.example.com", pds="pds.example.com")
        self.assertEqual(second, first)
        self.assertEqual(additions, [])
        self.assertEqual(second.count("appview.example.com {"), 1)

    def test_explicit_new_interface_replaces_only_binding(self):
        text = EXISTING.replace("{\n", "{\n  default_bind 10.42.1.135 # primary interface\n", 1)
        changed, _ = caddy.render(text, "10.42.1.200")
        self.assertEqual(changed, text.replace("10.42.1.135", "10.42.1.200"))

    def test_missing_global_block_keeps_existing_site(self):
        text = "other.example.com {\n  respond \"ok\"\n}\n"
        rendered, _ = caddy.render(text, "10.42.1.135", email="admin@example.com")
        self.assertTrue(rendered.endswith(text))
        self.assertEqual(caddy.configured_binding(rendered), "10.42.1.135")

    def test_fresh_site_template_uses_the_selected_interface(self):
        rendered, additions = caddy.render("", "10.42.1.135", "admin@example.com", "torah.example.com", "appview.example.com", "pds.example.com")
        self.assertEqual(caddy.configured_binding(rendered), "10.42.1.135")
        self.assertEqual(len(additions), 3)
        self.assertEqual(caddy.site_names(rendered), {"torah.example.com", "appview.example.com", "pds.example.com", "*.pds.example.com"})
        self.assertIn("ask http://localhost:3000/tls-check", rendered)

    def test_known_old_permission_typo_is_scoped(self):
        text = EXISTING.replace("ask http://localhost:3000/tls-check", "task http://localhost:3000/tls-check")
        changed, _ = caddy.render(text, "10.42.1.135")
        self.assertNotIn("task http://localhost:3000/tls-check", changed)
        self.assertIn('header X-Example "literal } { and # stay untouched"', changed)

    def test_partial_existing_pds_block_does_not_create_duplicate_wildcard(self):
        text = EXISTING.replace("*.pds.example.com, pds.example.com", "*.pds.example.com")
        with self.assertRaises(ValueError):
            caddy.render(text, "10.42.1.135", pds="pds.example.com")

    def test_rejects_injection_and_wildcard_binding(self):
        for value in ("0.0.0.0", "127.0.0.1", "100.119.51.66", "::", "169.254.1.1"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                caddy.render(EXISTING, value)
        with self.assertRaises(ValueError):
            caddy.render(EXISTING, "10.42.1.135", web="evil.example {\n respond hacked\n}")

    def test_default_route_ignores_loopback_and_tailnet(self):
        interfaces = [
            {"ifname": "lo", "addr_info": [{"family": "inet", "scope": "host", "local": "127.0.0.1"}]},
            {"ifname": "tailscale0", "addr_info": [{"family": "inet", "scope": "global", "local": "100.119.51.66"}]},
            {"ifname": "enp0s6", "addr_info": [{"family": "inet", "scope": "global", "local": "10.42.1.135"}]},
        ]
        routes = [{"dev": "tailscale0", "metric": 0}, {"dev": "enp0s6", "metric": 100}]
        self.assertEqual(caddy.select_address(None, None, interfaces, routes), "10.42.1.135")
        with self.assertRaises(ValueError):
            caddy.select_address("100.119.51.66", None, interfaces, routes)
        with self.assertRaises(ValueError):
            caddy.select_address("10.42.1.999", None, interfaces, routes)

    def test_ambiguous_interface_requires_explicit_address(self):
        interfaces = [{"ifname": "eth0", "addr_info": [
            {"family": "inet", "scope": "global", "local": "10.1.1.2"},
            {"family": "inet", "scope": "global", "local": "10.1.1.3"},
        ]}]
        with self.assertRaises(ValueError):
            caddy.select_address(None, None, interfaces, [{"dev": "eth0"}])
        self.assertEqual(caddy.select_address("10.1.1.3", None, interfaces, []), "10.1.1.3")

    def test_reload_failure_restores_file_and_reloads_original(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Caddyfile"
            candidate = Path(directory) / "candidate"
            original = EXISTING.encode()
            path.write_bytes(original)
            os.chmod(path, 0o640)
            candidate.write_text(caddy.render(EXISTING, "10.42.1.135")[0])
            seen = []

            def reload_config():
                seen.append(path.read_bytes())
                if len(seen) == 1:
                    raise RuntimeError("deliberate reload failure")

            with self.assertRaisesRegex(RuntimeError, "restored and reloaded"):
                caddy.apply_candidate(path, candidate, original, reload_config)
            self.assertEqual(path.read_bytes(), original)
            self.assertNotEqual(seen[0], original)
            self.assertEqual(seen[1], original)
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)
            self.assertEqual(len(list(Path(directory).glob("Caddyfile.before-torah-bind-*"))), 1)

    def test_concurrent_edit_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Caddyfile"
            candidate = Path(directory) / "candidate"
            path.write_text("a newer operator edit")
            candidate.write_text("candidate")
            with self.assertRaisesRegex(RuntimeError, "concurrent edits"):
                caddy.apply_candidate(path, candidate, EXISTING.encode(), lambda: None)
            self.assertEqual(path.read_text(), "a newer operator edit")


if __name__ == "__main__":
    unittest.main()
