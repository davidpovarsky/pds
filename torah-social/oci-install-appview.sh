#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${REGION:-il-jerusalem-1}"
INSTANCE_NAME="${INSTANCE_NAME:-torah-social}"
KEY_PATH="${HOME}/.ssh/torah-social-oci"
OCI_CONFIG_FILE="${OCI_CLI_CONFIG_FILE:-/etc/oci/config}"

fail(){ echo "ERROR: $*" >&2; exit 1; }

[[ -r "${OCI_CONFIG_FILE}" ]] || fail "Run this from Oracle Cloud Shell."
[[ -f "${KEY_PATH}" ]] || fail "Missing SSH key ${KEY_PATH}."
TENANCY_ID="$(awk -F= '/^[[:space:]]*tenancy[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "${OCI_CONFIG_FILE}")"
[[ "${TENANCY_ID}" == ocid1.tenancy.* ]] || fail "Could not read tenancy OCID."

OCI=(oci --region "${REGION}")
INSTANCE_JSON="$("${OCI[@]}" compute instance list --compartment-id "${TENANCY_ID}" --display-name "${INSTANCE_NAME}" --all)"
INSTANCE_ID="$(printf '%s' "${INSTANCE_JSON}" | python3 -c '
import json,sys
xs=[x for x in json.load(sys.stdin).get("data",[]) if x.get("lifecycle-state") not in ("TERMINATED","TERMINATING")]
xs.sort(key=lambda x:x.get("time-created", ""), reverse=True)
print(xs[0]["id"] if xs else "")
')"
[[ "${INSTANCE_ID}" == ocid1.instance.* ]] || fail "No running ${INSTANCE_NAME} VM found."

VNIC_JSON="$("${OCI[@]}" compute instance list-vnics --instance-id "${INSTANCE_ID}" --all)"
PUBLIC_IP="$(printf '%s' "${VNIC_JSON}" | python3 -c '
import json,sys
xs=json.load(sys.stdin).get("data",[])
print(xs[0].get("public-ip","") if xs else "")
')"
[[ "${PUBLIC_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "The VM has no public IPv4 address."

SSH=(ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=20 -o StrictHostKeyChecking=accept-new -i "${KEY_PATH}" "ubuntu@${PUBLIC_IP}")

echo "Torah Social VM: ${PUBLIC_IP}"

# If the isolated AppView is already fully installed and healthy, do not rebuild it.
if "${SSH[@]}" 'sudo test -f /pds/torah-appview-info && curl -fsS --max-time 3 http://127.0.0.1:2584/xrpc/_health >/dev/null 2>&1'; then
  echo "Torah AppView is already installed and healthy."
  "${SSH[@]}" 'sudo cat /pds/torah-appview-info'
  exit 0
fi

# Start the installation on the VM itself. nohup means it survives an iPad/Safari
# or Cloud Shell disconnect. Re-running this helper while it is active only
# reconnects to its status instead of starting a duplicate build.
if ! "${SSH[@]}" 'sudo test -f /var/run/torah-appview-install.running'; then
  echo "Starting isolated Torah AppView installation in the VM background."
  echo "The first atproto build can take several minutes."
  "${SSH[@]}" 'curl -fsSL https://raw.githubusercontent.com/davidpovarsky/pds/codex/torah-social-foundation/torah-social/install-appview.sh -o /tmp/install-appview.sh && sudo rm -f /var/run/torah-appview-install.exit && sudo touch /var/run/torah-appview-install.running && sudo sh -c '\''nohup bash -c "bash /tmp/install-appview.sh; rc=\$?; echo \$rc > /var/run/torah-appview-install.exit; rm -f /var/run/torah-appview-install.running" > /var/log/torah-appview-install.log 2>&1 < /dev/null &'\'''
else
  echo "An AppView installation is already running; reconnecting to its status."
fi

echo
for _ in $(seq 1 240); do
  if "${SSH[@]}" 'sudo test -f /var/run/torah-appview-install.exit'; then
    RC="$("${SSH[@]}" 'sudo cat /var/run/torah-appview-install.exit')"
    echo
    echo "================ final installer output ================"
    "${SSH[@]}" 'sudo tail -n 100 /var/log/torah-appview-install.log'
    echo "========================================================"
    if [[ "${RC}" == "0" ]]; then
      echo "Torah Social isolated AppView installation COMPLETE."
      exit 0
    fi
    fail "AppView installation stopped with exit code ${RC}. The exact failure is above."
  fi

  STATUS="$("${SSH[@]}" "sudo grep '^==>' /var/log/torah-appview-install.log 2>/dev/null | tail -n 1" || true)"
  if [[ -n "${STATUS}" ]]; then
    printf '%s\r' "${STATUS}"
  else
    printf '%s\r' "Installing..."
  fi
  sleep 15
done

echo
fail "The installer is still running after one hour. It continues on the VM; rerun this helper to reconnect to its status."
