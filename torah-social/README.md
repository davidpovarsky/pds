# Torah Social experimental server

This directory turns a normal Ubuntu/Debian VM into the first Torah Social test server.

It deploys:

- the official AT Protocol PDS with persistent data in `/pds`;
- the Torah Social web client from `davidpovarsky/social-app`, branch `codex/torah-social-foundation`;
- Caddy HTTPS for both services;
- invite-only account creation;
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
git clone --branch codex/torah-social-foundation --single-branch https://github.com/davidpovarsky/pds.git
cd pds
sudo ADMIN_EMAIL=you@example.com bash torah-social/install.sh
```

The installer prints:

- the Torah Social web URL;
- the PDS URL;
- the handle suffix;
- a one-use signup invite code.

A fresh invite can be created later with:

```bash
sudo pdsadmin create-invite-code
```

## Persistence

PDS accounts, repositories, blobs, keys and configuration live under `/pds`. Rebuilding or replacing the Torah Social web container does not erase them.

## Architecture during the experiment

```text
Browser / app
    |
    +--> Torah Social web (localhost:8100)
    |
    +--> Torah Social PDS (localhost:3000)
              |
              +--> public Bluesky AppView for social aggregation, temporarily

Caddy owns public ports 80/443 and routes the two hostnames.
```

This is intentionally an intermediate **backend architecture**, not a throwaway web preview: accounts are created on our PDS. The remaining dependency on Bluesky's public AppView is replaced later when the Torah Social AppView/social backend is deployed from the AT Protocol stack.

## Updating the web client

Re-run:

```bash
sudo bash torah-social/install.sh
```

The script preserves `/pds`, fast-forwards the server checkout to the current Torah Social branch, rebuilds the web image and restarts only the web container/Caddy as needed.
