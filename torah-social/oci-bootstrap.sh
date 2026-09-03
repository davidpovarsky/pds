#!/usr/bin/env bash
set -Eeuo pipefail

# Torah Social - Oracle Cloud one-command bootstrap
# Run this from OCI Cloud Shell. Cloud Shell already has an authenticated OCI CLI.
#
# This script creates/reuses:
#   - a VCN
#   - an Internet Gateway
#   - a public subnet
#   - route/security rules for SSH, HTTP, and HTTPS
#   - an Always Free-eligible VM.Standard.A1.Flex instance (2 OCPU / 12 GB)
#   - an ephemeral public IPv4 address
#
# The VM then installs Torah Social + the PDS automatically through cloud-init.

REGION="${REGION:-il-jerusalem-1}"
VCN_NAME="${VCN_NAME:-torah-social-vcn}"
SUBNET_NAME="${SUBNET_NAME:-torah-social-public-subnet}"
IGW_NAME="${IGW_NAME:-torah-social-internet-gateway}"
INSTANCE_NAME="${INSTANCE_NAME:-torah-social}"
VCN_CIDR="${VCN_CIDR:-10.42.0.0/16}"
SUBNET_CIDR="${SUBNET_CIDR:-10.42.1.0/24}"
SHAPE="VM.Standard.A1.Flex"
OCPUS=2
MEMORY_GB=12
KEY_PATH="${HOME}/.ssh/torah-social-oci"
PDS_REPO="https://github.com/davidpovarsky/pds.git"
PDS_BRANCH="codex/torah-social-foundation"

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

json_file() {
  local name="$1"
  local body="$2"
  local path
  path="$(mktemp "${TMPDIR:-/tmp}/${name}.XXXXXX.json")"
  printf '%s\n' "$body" >"${path}"
  printf '%s' "${path}"
}

first_non_null() {
  local value="$1"
  if [[ -n "${value}" && "${value}" != "null" && "${value}" != "None" ]]; then
    printf '%s' "${value}"
  fi
}

require oci
require ssh-keygen
require curl

log "Using Oracle region ${REGION}"

TENANCY_ID="${OCI_CLI_TENANCY:-}"
if [[ -z "${TENANCY_ID}" && -f "${HOME}/.oci/config" ]]; then
  TENANCY_ID="$(awk -F= '/^[[:space:]]*tenancy[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "${HOME}/.oci/config" || true)"
fi
if [[ -z "${TENANCY_ID}" ]]; then
  read -r -p "Paste your Oracle Tenancy OCID: " TENANCY_ID
fi
[[ "${TENANCY_ID}" == ocid1.tenancy.* ]] || fail "Could not determine a valid tenancy OCID."

COMPARTMENT_ID="${COMPARTMENT_ID:-${TENANCY_ID}}"

ADMIN_EMAIL="${ADMIN_EMAIL:-}"
if [[ -z "${ADMIN_EMAIL}" ]]; then
  read -r -p "Admin email for HTTPS certificate notices: " ADMIN_EMAIL
fi
[[ "${ADMIN_EMAIL}" == *@*.* ]] || fail "Please provide a valid email address."

OCI=(oci --region "${REGION}")

log "Checking Oracle access"
"${OCI[@]}" iam availability-domain list \
  --compartment-id "${TENANCY_ID}" >/dev/null

AD_NAME="$("${OCI[@]}" iam availability-domain list \
  --compartment-id "${TENANCY_ID}" \
  --query 'data[0].name' \
  --raw-output)"
[[ -n "${AD_NAME}" && "${AD_NAME}" != "null" ]] || fail "No availability domain found in ${REGION}."

log "Creating/reusing VCN"
VCN_ID="$("${OCI[@]}" network vcn list \
  --compartment-id "${COMPARTMENT_ID}" \
  --display-name "${VCN_NAME}" \
  --lifecycle-state AVAILABLE \
  --query 'data[0].id' \
  --raw-output 2>/dev/null || true)"
VCN_ID="$(first_non_null "${VCN_ID}")"
if [[ -z "${VCN_ID}" ]]; then
  VCN_ID="$("${OCI[@]}" network vcn create \
    --compartment-id "${COMPARTMENT_ID}" \
    --cidr-block "${VCN_CIDR}" \
    --display-name "${VCN_NAME}" \
    --dns-label torahsocial \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output)"
fi

VCN_JSON="$("${OCI[@]}" network vcn get --vcn-id "${VCN_ID}")"
ROUTE_TABLE_ID="$(printf '%s' "${VCN_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["default-route-table-id"])')"
SECURITY_LIST_ID="$(printf '%s' "${VCN_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["default-security-list-id"])')"

log "Creating/reusing Internet Gateway"
IGW_ID="$("${OCI[@]}" network internet-gateway list \
  --compartment-id "${COMPARTMENT_ID}" \
  --vcn-id "${VCN_ID}" \
  --display-name "${IGW_NAME}" \
  --query 'data[0].id' \
  --raw-output 2>/dev/null || true)"
IGW_ID="$(first_non_null "${IGW_ID}")"
if [[ -z "${IGW_ID}" ]]; then
  IGW_ID="$("${OCI[@]}" network internet-gateway create \
    --compartment-id "${COMPARTMENT_ID}" \
    --vcn-id "${VCN_ID}" \
    --display-name "${IGW_NAME}" \
    --is-enabled true \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output)"
fi

log "Configuring Internet route"
ROUTE_RULES="$(json_file torah-route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"${IGW_ID}\"}]")"
"${OCI[@]}" network route-table update \
  --rt-id "${ROUTE_TABLE_ID}" \
  --route-rules "file://${ROUTE_RULES}" \
  --force \
  --wait-for-state AVAILABLE >/dev/null
rm -f "${ROUTE_RULES}"

log "Opening only the required inbound ports (22, 80, 443)"
INGRESS_RULES='[
  {"protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},
  {"protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":80,"max":80}}},
  {"protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":443,"max":443}}}
]'
EGRESS_RULES='[
  {"protocol":"all","destination":"0.0.0.0/0","destinationType":"CIDR_BLOCK","isStateless":false}
]'
INGRESS_FILE="$(json_file torah-ingress "${INGRESS_RULES}")"
EGRESS_FILE="$(json_file torah-egress "${EGRESS_RULES}")"
"${OCI[@]}" network security-list update \
  --security-list-id "${SECURITY_LIST_ID}" \
  --ingress-security-rules "file://${INGRESS_FILE}" \
  --egress-security-rules "file://${EGRESS_FILE}" \
  --force \
  --wait-for-state AVAILABLE >/dev/null
rm -f "${INGRESS_FILE}" "${EGRESS_FILE}"

log "Creating/reusing public subnet"
SUBNET_ID="$("${OCI[@]}" network subnet list \
  --compartment-id "${COMPARTMENT_ID}" \
  --vcn-id "${VCN_ID}" \
  --display-name "${SUBNET_NAME}" \
  --lifecycle-state AVAILABLE \
  --query 'data[0].id' \
  --raw-output 2>/dev/null || true)"
SUBNET_ID="$(first_non_null "${SUBNET_ID}")"
if [[ -z "${SUBNET_ID}" ]]; then
  SUBNET_ID="$("${OCI[@]}" network subnet create \
    --compartment-id "${COMPARTMENT_ID}" \
    --vcn-id "${VCN_ID}" \
    --cidr-block "${SUBNET_CIDR}" \
    --display-name "${SUBNET_NAME}" \
    --dns-label public \
    --prohibit-public-ip-on-vnic false \
    --route-table-id "${ROUTE_TABLE_ID}" \
    --security-list-ids "[\"${SECURITY_LIST_ID}\"]" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output)"
fi

log "Preparing persistent SSH key in Cloud Shell"
mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"
if [[ ! -f "${KEY_PATH}" ]]; then
  ssh-keygen -q -t rsa -b 4096 -N '' -C 'torah-social-oci' -f "${KEY_PATH}"
fi
chmod 600 "${KEY_PATH}"

log "Locating current Canonical Ubuntu 24.04 ARM image"
IMAGE_ID="$("${OCI[@]}" compute image list \
  --compartment-id "${COMPARTMENT_ID}" \
  --operating-system 'Canonical Ubuntu' \
  --operating-system-version '24.04' \
  --shape "${SHAPE}" \
  --sort-by TIMECREATED \
  --sort-order DESC \
  --limit 1 \
  --query 'data[0].id' \
  --raw-output)"
[[ -n "${IMAGE_ID}" && "${IMAGE_ID}" != "null" ]] || fail "Could not find an Ubuntu 24.04 image compatible with ${SHAPE}."

log "Checking for an existing Torah Social VM"
INSTANCE_ID="$("${OCI[@]}" compute instance list \
  --compartment-id "${COMPARTMENT_ID}" \
  --display-name "${INSTANCE_NAME}" \
  --query 'data[?"lifecycle-state"!=`TERMINATED`][0].id' \
  --raw-output 2>/dev/null || true)"
INSTANCE_ID="$(first_non_null "${INSTANCE_ID}")"

if [[ -z "${INSTANCE_ID}" ]]; then
  log "Launching Always Free-eligible A1 VM (2 OCPU / 12 GB)"

  EMAIL_B64="$(printf '%s' "${ADMIN_EMAIL}" | base64 | tr -d '\n')"
  USER_DATA="$(mktemp "${TMPDIR:-/tmp}/torah-cloud-init.XXXXXX.sh")"
  cat >"${USER_DATA}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee -a /var/log/torah-social-bootstrap.log | logger -t torah-social-bootstrap -s 2>/dev/console) 2>&1
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y git curl ca-certificates
rm -rf /opt/torah-social-pds
git clone --branch '${PDS_BRANCH}' --single-branch '${PDS_REPO}' /opt/torah-social-pds
cd /opt/torah-social-pds
ADMIN_EMAIL=\"\$(printf '%s' '${EMAIL_B64}' | base64 -d)\" bash torah-social/install.sh
EOF
  chmod 600 "${USER_DATA}"

  set +e
  LAUNCH_OUTPUT="$("${OCI[@]}" compute instance launch \
    --availability-domain "${AD_NAME}" \
    --compartment-id "${COMPARTMENT_ID}" \
    --display-name "${INSTANCE_NAME}" \
    --shape "${SHAPE}" \
    --shape-config '{"ocpus":2,"memoryInGBs":12}' \
    --image-id "${IMAGE_ID}" \
    --subnet-id "${SUBNET_ID}" \
    --assign-public-ip true \
    --assign-private-dns-record true \
    --hostname-label torah-social \
    --ssh-authorized-keys-file "${KEY_PATH}.pub" \
    --user-data-file "${USER_DATA}" \
    --wait-for-state RUNNING \
    --query 'data.id' \
    --raw-output 2>&1)"
  LAUNCH_STATUS=$?
  set -e
  rm -f "${USER_DATA}"

  if [[ ${LAUNCH_STATUS} -ne 0 ]]; then
    echo "${LAUNCH_OUTPUT}" >&2
    if grep -qiE 'capacity|out of host|not available' <<<"${LAUNCH_OUTPUT}"; then
      fail "Oracle currently has no A1 capacity in ${REGION}. Nothing was charged. Retry this same command later."
    fi
    fail "Oracle could not launch the VM. See the error above."
  fi
  INSTANCE_ID="${LAUNCH_OUTPUT}"
else
  log "Existing VM found; leaving it intact"
fi

log "Reading the public IPv4 address"
VNIC_ID=""
for _ in $(seq 1 30); do
  VNIC_ID="$("${OCI[@]}" compute vnic-attachment list \
    --compartment-id "${COMPARTMENT_ID}" \
    --instance-id "${INSTANCE_ID}" \
    --query 'data[0]."vnic-id"' \
    --raw-output 2>/dev/null || true)"
  VNIC_ID="$(first_non_null "${VNIC_ID}")"
  [[ -n "${VNIC_ID}" ]] && break
  sleep 2
done
[[ -n "${VNIC_ID}" ]] || fail "VM exists but its VNIC was not found yet."

PUBLIC_IP=""
for _ in $(seq 1 30); do
  PUBLIC_IP="$("${OCI[@]}" network vnic get \
    --vnic-id "${VNIC_ID}" \
    --query 'data."public-ip"' \
    --raw-output 2>/dev/null || true)"
  PUBLIC_IP="$(first_non_null "${PUBLIC_IP}")"
  [[ -n "${PUBLIC_IP}" ]] && break
  sleep 2
done
[[ -n "${PUBLIC_IP}" ]] || fail "VM was created, but Oracle did not assign a public IPv4 address."

IP_DASH="${PUBLIC_IP//./-}"
WEB_HOST="torah-${IP_DASH}.nip.io"
PDS_HOST="pds-${IP_DASH}.nip.io"

cat <<EOF

========================================================================
Oracle infrastructure is ready. No more Oracle setup screens are needed.
========================================================================
VM:           ${INSTANCE_NAME}
Region:       ${REGION}
Shape:        ${SHAPE} (${OCPUS} OCPU / ${MEMORY_GB} GB RAM)
Public IPv4:  ${PUBLIC_IP}
Web URL:      https://${WEB_HOST}
PDS URL:      https://${PDS_HOST}
SSH key:      ${KEY_PATH}

Torah Social is now installing automatically on the VM. The first build can
take a while. You can watch it from this same Cloud Shell with:

  ssh -o StrictHostKeyChecking=accept-new -i ${KEY_PATH} ubuntu@${PUBLIC_IP} 'sudo tail -f /var/log/torah-social-bootstrap.log'

When installation finishes, the invite code is available with:

  ssh -i ${KEY_PATH} ubuntu@${PUBLIC_IP} 'sudo cat /pds/torah-social-invite-code.txt'

You can rerun this bootstrap script safely; it reuses the named resources.
========================================================================
EOF
