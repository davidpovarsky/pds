# Torah Social experimental server

This directory turns a normal Ubuntu/Debian VM into the first Torah Social test server.

It deploys:

- the official AT Protocol PDS with persistent data in `/pds`;
- the Torah Social web client from `davidpovarsky/social-app`, with the source branch controlled by `SOCIAL_APP_BRANCH`;
- Caddy HTTPS for both services;
- open account creation (`PDS_INVITE_REQUIRED=false`);
- a free temporary `nip.io` hostname derived from the VM public IPv4 address.

The temporary hostnames are only DNS names. The application and PDS data remain portable to a permanent domain later.

## VM requirements

- Ubuntu 22.04/24.04 or Debian 12/13
- amd64 or arm64/aarch64
- public IPv4 address
- inbound TCP ports 22, 80 and 443 allowed by the cloud firewall
- at least 2 vCPU and enough RAM to build the web client (Oracle A1 2 OCPU / 12 GB is suitable for the experimental stage)

## Install

Clone this branch on the VM and run the installer as root:

```bash
git clone --branch codex/torah-social-runtime-repair --single-branch https://github.com/davidpovarsky/pds.git
cd pds
sudo ADMIN_EMAIL=you@example.com bash torah-social/install.sh
```

The installer prints:

- the Torah Social web URL;
- the PDS URL;
- the handle suffix;
- open-registration status.

A fresh invite can be created later with:

```bash
sudo pdsadmin create-invite-code
```

## Persistence

PDS accounts, repositories, blobs, keys and configuration live under `/pds`. Rebuilding or replacing the Torah Social web container does not erase them.

## Shared HTTPS and the isolated AppView

The AppView installer adds the private Torah Social AppView on loopback port 2584. The web client uses loopback port 8100, and the PDS uses port 3000. The public hostnames route to these separate services through Caddy; Torah Social does not use the public Bluesky AppView.

Caddy can share a VM with Tailscale Serve. Its HTTPS listener must bind to the VM's primary interface address, rather than all interfaces. On a cloud VM behind NAT this is the assigned private IPv4 address, not the externally visible public IPv4 address. A wildcard listener can collide with Tailscale's listener and prevent every public hostname from loading.

Both Torah installers use `configure-caddy.py` to preserve all existing site blocks, including the PDS DID document handler and unrelated services. Missing Torah site blocks are appended. Existing site blocks are never replaced. The helper keeps an existing valid primary-interface binding, or detects the primary IPv4 from the default route. Set `CADDY_BIND_ADDRESS` explicitly when the host has multiple suitable addresses. Loopback, wildcard, unassigned and Tailscale addresses are rejected.

For an existing shared server, inspect the targeted Caddy repair without rebuilding or restarting the PDS, AppView or web client:

```bash
sudo python3 torah-social/configure-caddy.py --dry-run
# Optional explicit interface address:
sudo CADDY_BIND_ADDRESS=10.42.1.135 python3 torah-social/configure-caddy.py --dry-run
```

Apply the verified change with:

```bash
sudo python3 torah-social/configure-caddy.py --apply
```

The dry-run validates a temporary candidate with the exact deployed Caddy image and read-only mounts. Applying first creates `Caddyfile.before-torah-bind-<UTC timestamp>` beside the live file, atomically replaces the configuration and reloads only Caddy. A failed reload restores and reloads the original. An unchanged configuration needs no reload. The helper does not alter Tailscale settings, certificates, user data, containers other than Caddy, or existing site blocks. Explicit site-level bind overrides outside the chosen primary address require operator review and fail validation without replacing the active file.

After applying, verify the public web URL plus `/xrpc/_health` on the PDS and AppView hostnames. Configuration validation cannot prove cloud firewall rules, DNS or external reachability. The saved backup can also be copied back and loaded with `docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile`.

The standalone Oracle helper downloads `install-appview.sh` and `configure-caddy.py` from the same `PDS_BRANCH`. This source ref is separate from `ATPROTO_BRANCH`. A complete Git checkout is required for the base installer.

References: [Caddy default_bind](https://caddyserver.com/docs/caddyfile/options#default-bind), [configuration validation and reload](https://caddyserver.com/docs/command-line).

## Updating the web client

Re-run:

```bash
sudo bash torah-social/install.sh
```

The script preserves `/pds`, fast-forwards the server checkout to the current Torah Social branch, rebuilds the web image and restarts only the web container/Caddy as needed.
