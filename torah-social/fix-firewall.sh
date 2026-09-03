#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run with sudo/root." >&2
  exit 1
fi

# Oracle's Ubuntu images can require explicit iptables rules in addition to the
# OCI VCN security list. Preserve Oracle's existing rules and insert only the
# web ports Torah Social needs.
for port in 80 443; do
  if ! iptables -C INPUT -m state --state NEW -p tcp --dport "${port}" -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 6 -m state --state NEW -p tcp --dport "${port}" -j ACCEPT
  fi
done

if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y iptables-persistent
  netfilter-persistent save
fi

# Caddy can retry ACME immediately after the ports become reachable.
docker restart caddy >/dev/null 2>&1 || systemctl restart pds

echo "Host firewall now allows TCP 80 and 443, and Caddy was restarted."
