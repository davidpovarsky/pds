#!/usr/bin/env python3
"""Preserve a shared PDS Caddyfile while selecting its public-facing interface.

Dry-run is the default. Applying validates with the deployed Caddy image,
backs up the original, atomically replaces it and reloads only Caddy. A failed
reload restores the exact previous file. Existing site blocks are never replaced.
"""

import argparse
import hashlib
import ipaddress
import json
import os
import re
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path


TOKEN = re.compile(r'#[^\n]*|"(?:\\.|[^"\\])*"|`[^`]*`|[^\s#]+')
TAILNET = ipaddress.ip_network("100.64.0.0/10")


def run(command):
    result = subprocess.run(command, text=True, capture_output=True, timeout=60)
    if result.returncode:
        raise RuntimeError(f"{command[0]} failed ({result.returncode}): {result.stderr[-3000:]}")
    return result.stdout


def tokens(text):
    return [match for match in TOKEN.finditer(text) if not match.group().startswith("#")]


def global_block(text):
    items = tokens(text)
    if not items or items[0].group() != "{":
        return None, []
    depth = 0
    bindings = []
    for item in items:
        value = item.group()
        if value == "{":
            depth += 1
        elif value == "}":
            depth -= 1
            if depth == 0:
                return (items[0].end(), item.start()), bindings
        elif depth == 1 and value == "default_bind":
            end = text.find("\n", item.end())
            end = len(text) if end < 0 else end
            bindings.append((item.start(), end))
    raise ValueError("Unclosed global Caddy options block")


def configured_binding(text):
    _, bindings = global_block(text)
    if len(bindings) > 1:
        raise ValueError("Multiple default_bind directives require manual consolidation")
    if not bindings:
        return None
    start, end = bindings[0]
    values = text[start:end].split("#", 1)[0].split()[1:]
    if len(values) != 1:
        raise ValueError("Multiple/default_bind placeholders require an explicit single-IP configuration")
    return values[0]


def valid_address(value):
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return False
    return (
        address.version == 4 and not address.is_unspecified
        and not address.is_loopback and not address.is_link_local
        and not address.is_multicast and address not in TAILNET
    )


def select_address(requested, current, interfaces, routes):
    addresses = {
        item["ifname"]: [
            entry["local"] for entry in item.get("addr_info", [])
            if entry.get("family") == "inet" and entry.get("scope") == "global"
            and valid_address(entry["local"])
        ]
        for item in interfaces
        if item["ifname"] != "lo" and not item["ifname"].startswith("tailscale")
    }
    assigned = {value for values in addresses.values() for value in values}
    if requested:
        if requested not in assigned:
            raise ValueError("CADDY_BIND_ADDRESS must be an assigned non-loopback, non-Tailscale IPv4 address")
        return requested
    if current in assigned:
        return current
    candidates = [item for item in routes if addresses.get(item.get("dev"))]
    if not candidates:
        raise ValueError("No primary IPv4 interface found; set CADDY_BIND_ADDRESS explicitly")
    metric = min(item.get("metric", 0) for item in candidates)
    primary = [item for item in candidates if item.get("metric", 0) == metric]
    choices = set()
    for route in primary:
        preferred = route.get("prefsrc")
        values = addresses[route["dev"]]
        choices.update([preferred] if preferred in values else values)
    if len(choices) != 1:
        raise ValueError("Ambiguous primary IPv4 addresses; set CADDY_BIND_ADDRESS explicitly")
    return choices.pop()


def patch_binding(text, address, email):
    block, bindings = global_block(text)
    if len(bindings) > 1:
        raise ValueError("Multiple default_bind directives require manual consolidation")
    if bindings:
        if configured_binding(text) == address:
            return text
        start, end = bindings[0]
        comment = text[start:end].partition("#")[2]
        suffix = f" # {comment.strip()}" if comment else ""
        return text[:start] + f"default_bind {address}{suffix}" + text[end:]
    if block:
        start, _ = block
        return text[:start] + f"\n  default_bind {address}" + text[start:]
    email_line = f"  email {email}\n" if email else ""
    return (
        "{\n" + f"  default_bind {address}\n" + email_line
        + "  on_demand_tls {\n    ask http://localhost:3000/tls-check\n  }\n}\n\n" + text
    )


def site_names(text):
    depth, pending, names = 0, [], set()
    for item in tokens(text):
        value = item.group()
        if value == "{":
            if depth == 0:
                names.update(part.strip('"`') for token in pending for part in token.split(",") if part)
                pending = []
            depth += 1
        elif value == "}":
            depth -= 1
            if depth == 0:
                pending = []
        elif depth == 0:
            pending.append(value)
    return names


def render(text, address, email="", web=None, appview=None, pds=None):
    if not valid_address(address):
        raise ValueError("A specific non-Tailscale IPv4 binding is required")
    if email and not re.fullmatch(r"[^\s@{}]+@[^\s@{}]+", email):
        raise ValueError("Invalid administrator email")
    for hostname in (web, appview, pds):
        if hostname and not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", hostname):
            raise ValueError("Hostnames must be plain DNS names without a scheme, port or Caddy syntax")
    result = patch_binding(text, address, email)
    # Compatibility with the old upstream installer spelling, only for its known endpoint.
    result = re.sub(r"(?m)^([ \t]*)task[ \t]+http://localhost:3000/tls-check[ \t]*$", r"\1ask http://localhost:3000/tls-check", result)
    existing = site_names(result)
    additions = []
    for hostname, port in ((web, 8100), (appview, 2584)):
        if hostname and hostname not in existing:
            additions.append(f"{hostname} {{\n  reverse_proxy http://127.0.0.1:{port}\n}}\n")
    if pds:
        present = {pds, f"*.{pds}"} & existing
        if present and len(present) != 2:
            raise ValueError("Existing PDS hostname/wildcard coverage differs; preserve it and configure explicitly")
        if not present:
            additions.append(f"*.{pds}, {pds} {{\n  tls {{\n    on_demand\n  }}\n  reverse_proxy http://localhost:3000\n}}\n")
    if additions:
        result = result.rstrip() + "\n\n" + "\n".join(additions)
    return result, additions


def apply_candidate(path, candidate, original, reload_config):
    """Rollback is exercised by tests with a deliberately failing reload."""
    if path.read_bytes() != original:
        raise RuntimeError("Caddyfile changed during validation; refusing to overwrite concurrent edits")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup = path.with_name(f"Caddyfile.before-torah-bind-{stamp}")
    shutil.copy2(path, backup)
    shutil.copystat(path, candidate)
    owner = path.stat()
    os.chown(candidate, owner.st_uid, owner.st_gid)
    os.replace(candidate, path)
    try:
        reload_config()
    except Exception as error:
        restore = backup.with_name(backup.name + ".restore")
        shutil.copy2(backup, restore)
        os.chown(restore, owner.st_uid, owner.st_gid)
        os.replace(restore, path)
        try:
            reload_config()
        except Exception as rollback_error:
            raise RuntimeError(f"Caddy reload failed; original file restored at {path}. Rollback reload also failed: {rollback_error}") from error
        raise RuntimeError(f"Caddy reload failed; original configuration restored and reloaded. Backup: {backup}") from error
    return backup


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--apply", action="store_true")
    parser.add_argument("--state-dir", default="/pds")
    parser.add_argument("--bind-address", default=os.environ.get("CADDY_BIND_ADDRESS"))
    parser.add_argument("--email", default="")
    parser.add_argument("--web-hostname")
    parser.add_argument("--appview-hostname")
    parser.add_argument("--pds-hostname")
    args = parser.parse_args()
    path = Path(args.state_dir) / "caddy/etc/caddy/Caddyfile"
    if not path.is_file() or path.is_symlink():
        raise RuntimeError(f"Missing {path}; install the upstream PDS stack before configuring shared Caddy")
    original = path.read_bytes()
    text = original.decode("utf-8")
    address = select_address(
        args.bind_address, configured_binding(text),
        json.loads(run(["ip", "-j", "-4", "address", "show"])),
        json.loads(run(["ip", "-j", "-4", "route", "show", "default"])),
    )
    rendered, additions = render(text, address, args.email, args.web_hostname, args.appview_hostname, args.pds_hostname)
    container = json.loads(run(["docker", "inspect", "caddy"]))[0]
    image = container["Image"]
    fd, filename = tempfile.mkstemp(prefix=".torah-caddy-candidate-", dir=path.parent)
    candidate = Path(filename)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write(rendered)
        # Reuse the exact deployed image and mounts, read-only. No image upgrade or pulls.
        command = ["docker", "run", "--rm", "--network", "none", "--entrypoint", "caddy"]
        for mount in container["Mounts"]:
            command += ["--mount", f"type=bind,src={mount['Source']},dst={mount['Destination']},readonly"]
        command += [image, "adapt", "--config", f"/etc/caddy/{candidate.name}", "--adapter", "caddyfile", "--validate"]
        adapted = json.loads(run(command))
        listeners = [listen for server in adapted.get("apps", {}).get("http", {}).get("servers", {}).values() for listen in server.get("listen", [])]
        if not listeners or any(not listen.startswith(address + ":") for listen in listeners):
            raise RuntimeError(f"Candidate contains listeners outside {address}: {listeners}; inspect explicit site bind directives")
        report = {
            "mode": "apply" if args.apply else "dry-run", "changed": rendered.encode() != original,
            "bind_address": address, "listeners": listeners, "added_site_blocks": len(additions),
            "image": image, "candidate_sha256": hashlib.sha256(rendered.encode()).hexdigest(),
            "validation": "passed", "existing_site_blocks": "preserved",
        }
        if args.apply and report["changed"]:
            def reload_config():
                state = json.loads(run(["docker", "inspect", "caddy"]))[0]["State"]
                if state["Running"] and not state.get("Restarting"):
                    run(["docker", "exec", "caddy", "caddy", "reload", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"])
                else:
                    run(["docker", "restart", "caddy"])
                    run(["docker", "exec", "caddy", "caddy", "reload", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"])
            report["backup"] = str(apply_candidate(path, candidate, original, reload_config))
            report["reload"] = "passed"
        print(json.dumps(report, indent=2))
    finally:
        candidate.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
