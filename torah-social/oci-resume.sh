#!/usr/bin/env bash
set -Eeuo pipefail

trap 'rc=$?; echo; echo "ERROR: failed at line ${BASH_LINENO[0]} (exit ${rc})" >&2; echo "COMMAND: ${BASH_COMMAND}" >&2' ERR

REGION="${REGION:-il-jerusalem-1}"
INSTANCE_NAME="${INSTANCE_NAME:-torah-social}"
KEY_PATH="${HOME}/.ssh/torah-social-oci"
OCI_CONFIG_FILE="${OCI_CLI_CONFIG_FILE:-/etc/oci/config}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -r "${OCI_CONFIG_FILE}" ]] || fail "Cloud Shell OCI config not found at ${OCI_CONFIG_FILE}."
TENANCY_ID="$(awk -F= '/^[[:space:]]*tenancy[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "${OCI_CONFIG_FILE}")"
[[ "${TENANCY_ID}" == ocid1.tenancy.* ]] || fail "Could not read tenancy OCID from Cloud Shell config."

OCI=(oci --region "${REGION}")

echo "==> Finding existing Torah Social VM"
INSTANCE_JSON="$("${OCI[@]}" compute instance list \
  --compartment-id "${TENANCY_ID}" \
  --display-name "${INSTANCE_NAME}" \
  --all)"

INSTANCE_INFO="$(printf '%s' "${INSTANCE_JSON}" | python3 -c '
import json,sys
items=json.load(sys.stdin).get("data",[])
items=[x for x in items if x.get("lifecycle-state") not in ("TERMINATED","TERMINATING")]
if not items:
    sys.exit(2)
items.sort(key=lambda x:x.get("time-created", ""), reverse=True)
x=items[0]
print(x.get("id", ""))
print(x.get("lifecycle-state", ""))
')" || fail "No existing ${INSTANCE_NAME} VM was found in the root compartment."

INSTANCE_ID="$(printf '%s\n' "${INSTANCE_INFO}" | sed -n '1p')"
INSTANCE_STATE="$(printf '%s\n' "${INSTANCE_INFO}" | sed -n '2p')"
[[ "${INSTANCE_ID}" == ocid1.instance.* ]] || fail "Oracle returned an invalid instance ID: ${INSTANCE_ID:-<empty>}"
echo "Instance: ${INSTANCE_ID}"
echo "State:    ${INSTANCE_STATE}"

echo "==> Reading its VNIC and public IPv4"
PUBLIC_IP=""
for _ in $(seq 1 30); do
  VNIC_JSON="$("${OCI[@]}" compute instance list-vnics \
    --instance-id "${INSTANCE_ID}" \
    --all 2>/dev/null || true)"
  PUBLIC_IP="$(printf '%s' "${VNIC_JSON}" | python3 -c '
import json,sys
try:
    items=json.load(sys.stdin).get("data",[])
except Exception:
    print("")
    raise SystemExit(0)
for x in items:
    ip=x.get("public-ip")
    if ip:
        print(ip)
        break
' 2>/dev/null || true)"
  [[ "${PUBLIC_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
  sleep 2
done

if ! [[ "${PUBLIC_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "Oracle found the VM, but it currently has no public IPv4 on its attached VNIC." >&2
  echo "Instance state: ${INSTANCE_STATE}" >&2
  echo "VNIC data:" >&2
  printf '%s\n' "${VNIC_JSON}" >&2
  exit 3
fi

IP_DASH="${PUBLIC_IP//./-}"
WEB_HOST="torah-${IP_DASH}.nip.io"
PDS_HOST="pds-${IP_DASH}.nip.io"

cat <<EOF

========================================================================
Oracle VM is alive
========================================================================
State:       ${INSTANCE_STATE}
Public IPv4: ${PUBLIC_IP}
Web URL:     https://${WEB_HOST}
PDS URL:     https://${PDS_HOST}
========================================================================
EOF

if [[ ! -f "${KEY_PATH}" ]]; then
  echo "SSH key ${KEY_PATH} is missing, so I cannot inspect installation from Cloud Shell yet."
  exit 0
fi

echo "==> Waiting for SSH"
SSH_READY=0
for _ in $(seq 1 40); do
  if ssh -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new \
    -i "${KEY_PATH}" "ubuntu@${PUBLIC_IP}" 'true' >/dev/null 2>&1; then
    SSH_READY=1
    break
  fi
  sleep 3
done

if [[ "${SSH_READY}" -ne 1 ]]; then
  echo "VM has a public IP, but SSH is not ready yet. Wait 1-2 minutes and run this resume script again."
  exit 0
fi

echo "==> Torah Social installer status"
ssh -o StrictHostKeyChecking=accept-new -i "${KEY_PATH}" "ubuntu@${PUBLIC_IP}" \
  'sudo tail -n 100 /var/log/torah-social-bootstrap.log 2>/dev/null || echo "Installer log not created yet."'

echo
if ssh -o StrictHostKeyChecking=accept-new -i "${KEY_PATH}" "ubuntu@${PUBLIC_IP}" \
  'sudo test -f /pds/torah-social-invite-code.txt'; then
  echo "========================================================================"
  echo "Torah Social installation is COMPLETE"
  echo "========================================================================"
  echo "Web:  https://${WEB_HOST}"
  echo "PDS:  https://${PDS_HOST}"
  echo -n "Invite code: "
  ssh -o StrictHostKeyChecking=accept-new -i "${KEY_PATH}" "ubuntu@${PUBLIC_IP}" \
    'sudo cat /pds/torah-social-invite-code.txt'
else
  echo "Torah Social is still installing or the installer stopped before completion."
  echo "The log shown above is the exact server-side status."
fi
