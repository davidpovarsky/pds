#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${REGION:-il-jerusalem-1}"
INSTANCE_NAME="${INSTANCE_NAME:-torah-social}"
KEY_PATH="${HOME}/.ssh/torah-social-oci"
OCI_CONFIG_FILE="${OCI_CLI_CONFIG_FILE:-/etc/oci/config}"

fail(){ echo "ERROR: $*" >&2; exit 1; }

command -v oci >/dev/null || fail "oci CLI missing"
command -v python3 >/dev/null || fail "python3 missing"
[[ -r "${OCI_CONFIG_FILE}" ]] || fail "Cloud Shell OCI config missing"
[[ -f "${KEY_PATH}" ]] || fail "SSH key missing: ${KEY_PATH}"

TENANCY_ID="$(awk -F= '/^[[:space:]]*tenancy[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "${OCI_CONFIG_FILE}")"
[[ "${TENANCY_ID}" == ocid1.tenancy.* ]] || fail "Could not read tenancy OCID"
OCI=(oci --region "${REGION}")

echo "==> Finding the actual running VM"
INSTANCE_JSON="$("${OCI[@]}" compute instance list --compartment-id "${TENANCY_ID}" --display-name "${INSTANCE_NAME}" --all)"
INSTANCE_ID="$(printf '%s' "${INSTANCE_JSON}" | python3 -c '
import json,sys
xs=[x for x in json.load(sys.stdin).get("data",[]) if x.get("lifecycle-state") not in ("TERMINATED","TERMINATING")]
xs.sort(key=lambda x:x.get("time-created", ""), reverse=True)
print(xs[0]["id"] if xs else "")
')"
[[ "${INSTANCE_ID}" == ocid1.instance.* ]] || fail "No running ${INSTANCE_NAME} instance found"
echo "Instance: ${INSTANCE_ID}"

echo "==> Reading the VNIC actually attached to that VM"
VNIC_JSON="$("${OCI[@]}" compute instance list-vnics --instance-id "${INSTANCE_ID}" --all)"
readarray -t VNIC_INFO < <(printf '%s' "${VNIC_JSON}" | python3 -c '
import json,sys
xs=json.load(sys.stdin).get("data",[])
if not xs: raise SystemExit(2)
x=xs[0]
print(x.get("id", ""))
print(x.get("subnet-id", ""))
print(x.get("public-ip", ""))
')
VNIC_ID="${VNIC_INFO[0]:-}"
SUBNET_ID="${VNIC_INFO[1]:-}"
PUBLIC_IP="${VNIC_INFO[2]:-}"
[[ "${VNIC_ID}" == ocid1.vnic.* ]] || fail "No attached VNIC found"
[[ "${SUBNET_ID}" == ocid1.subnet.* ]] || fail "No subnet found on VNIC"
[[ "${PUBLIC_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "No public IPv4 on VNIC"
echo "Public IP: ${PUBLIC_IP}"
echo "Subnet:    ${SUBNET_ID}"

IP_DASH="${PUBLIC_IP//./-}"
WEB_HOST="torah-${IP_DASH}.nip.io"
PDS_HOST="pds-${IP_DASH}.nip.io"

echo "==> Reading the subnet's REAL security lists"
SUBNET_JSON="$("${OCI[@]}" network subnet get --subnet-id "${SUBNET_ID}")"
SEC_IDS="$(printf '%s' "${SUBNET_JSON}" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["data"].get("security-list-ids",[])))')"
[[ -n "${SEC_IDS}" ]] || fail "Subnet has no security list IDs"

while IFS= read -r SEC_ID; do
  [[ -n "${SEC_ID}" ]] || continue
  echo "Repairing security list: ${SEC_ID}"
  SEC_JSON="$("${OCI[@]}" network security-list get --security-list-id "${SEC_ID}")"
  TMP="$(mktemp)"
  printf '%s' "${SEC_JSON}" | python3 -c '
import json,sys
obj=json.load(sys.stdin)["data"]
rules=obj.get("ingress-security-rules",[])

def has(port):
    for r in rules:
        if str(r.get("protocol")) != "6": continue
        t=r.get("tcp-options") or {}
        d=t.get("destination-port-range") or {}
        if d.get("min") <= port <= d.get("max") if isinstance(d.get("min"),int) and isinstance(d.get("max"),int) else False:
            src=r.get("source")
            if src=="0.0.0.0/0": return True
    return False
for port in (22,80,443):
    if not has(port):
        rules.append({
          "protocol":"6","source":"0.0.0.0/0","source-type":"CIDR_BLOCK","is-stateless":False,
          "tcp-options":{"destination-port-range":{"min":port,"max":port}}
        })
print(json.dumps(rules,separators=(",",":")))
' >"${TMP}"
  "${OCI[@]}" network security-list update \
    --security-list-id "${SEC_ID}" \
    --ingress-security-rules "file://${TMP}" \
    --force --wait-for-state AVAILABLE >/dev/null
  rm -f "${TMP}"
done <<<"${SEC_IDS}"

echo "==> Repairing Ubuntu firewall and checking listeners"
ssh -o StrictHostKeyChecking=accept-new -i "${KEY_PATH}" "ubuntu@${PUBLIC_IP}" 'sudo bash -s' <<'REMOTE'
set -Eeuo pipefail
for port in 80 443; do
  while iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; do
    iptables -D INPUT -p tcp --dport "$port" -j ACCEPT || break
  done
  iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT
done
if command -v ufw >/dev/null 2>&1; then
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
fi
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save >/dev/null 2>&1 || true
fi
docker restart caddy >/dev/null
sleep 3
echo "Listeners:"
ss -ltnp | grep -E ':(80|443)[[:space:]]' || true
echo "Containers:"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E 'NAMES|caddy|pds|torah-social-web' || true
REMOTE

echo "==> Testing HTTP from Oracle Cloud Shell"
HTTP_CODE="$(curl -sS -o /tmp/torah-http.out -w '%{http_code}' --connect-timeout 8 --max-time 15 "http://${WEB_HOST}/" || true)"
echo "HTTP ${WEB_HOST}: ${HTTP_CODE:-connection-failed}"

PDS_HTTP_CODE="$(curl -sS -o /tmp/pds-http.out -w '%{http_code}' --connect-timeout 8 --max-time 15 "http://${PDS_HOST}/xrpc/_health" || true)"
echo "HTTP ${PDS_HOST}: ${PDS_HTTP_CODE:-connection-failed}"

if [[ "${HTTP_CODE}" == "000" || -z "${HTTP_CODE}" || "${PDS_HTTP_CODE}" == "000" || -z "${PDS_HTTP_CODE}" ]]; then
  echo
  echo "WEB_ACCESS_STILL_BLOCKED"
  echo "Cloud firewall and host firewall were repaired, but Cloud Shell still cannot connect to port 80."
  exit 4
fi

echo "==> Waiting briefly for Caddy to obtain certificates"
HTTPS_OK=0
for _ in $(seq 1 24); do
  if curl -fsS --connect-timeout 5 --max-time 10 "https://${PDS_HOST}/xrpc/_health" >/dev/null 2>&1; then
    HTTPS_OK=1
    break
  fi
  sleep 5
done

if [[ "${HTTPS_OK}" -eq 1 ]]; then
  echo
  echo "WEB_ACCESS_FIXED"
  echo "Web: https://${WEB_HOST}"
  echo "PDS: https://${PDS_HOST}"
else
  echo
  echo "HTTP_IS_FIXED_BUT_HTTPS_CERTIFICATE_IS_NOT_READY"
  echo "Run: ssh -i ${KEY_PATH} ubuntu@${PUBLIC_IP} 'sudo docker logs --tail 80 caddy'"
fi
