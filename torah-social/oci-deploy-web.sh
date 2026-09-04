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
[[ "${INSTANCE_ID}" == ocid1.instance.* ]] || fail "No active ${INSTANCE_NAME} VM found."

VNIC_JSON="$("${OCI[@]}" compute instance list-vnics --instance-id "${INSTANCE_ID}" --all)"
PUBLIC_IP="$(printf '%s' "${VNIC_JSON}" | python3 -c '
import json,sys
xs=json.load(sys.stdin).get("data",[])
for x in xs:
    ip=x.get("public-ip")
    if ip:
        print(ip)
        break
')"
[[ "${PUBLIC_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "The VM has no public IPv4 address."

SSH=(ssh -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=20 -o StrictHostKeyChecking=accept-new -i "${KEY_PATH}" "ubuntu@${PUBLIC_IP}")

echo "Torah Social VM: ${PUBLIC_IP}"
echo "Deploying latest codex/torah-social-foundation web bundle..."

"${SSH[@]}" 'curl -fsSL https://raw.githubusercontent.com/davidpovarsky/pds/codex/torah-social-foundation/torah-social/deploy-web.sh -o /tmp/torah-social-deploy-web.sh && sudo bash /tmp/torah-social-deploy-web.sh'
