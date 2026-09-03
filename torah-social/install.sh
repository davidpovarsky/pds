#!/usr/bin/env bash
set -Eeuo pipefail

# Torah Social experimental deployment
#
# Installs the official PDS stack, builds davidpovarsky/social-app, and serves
# both through the PDS Caddy instance on a single Linux VM.
#
# First run:
#   sudo ADMIN_EMAIL=you@example.com bash torah-social/install.sh
#
# Optional overrides:
#   PUBLIC_IP=203.0.113.10
#   APP_HOSTNAME=app.example.com
#   PDS_HOSTNAME=pds.example.com

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run this installer as root (sudo)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="/pds"
TORAH_DIR="/opt/torah-social"
SOCIAL_APP_DIR="${TORAH_DIR}/social-app"
SOCIAL_APP_REPO="https://github.com/davidpovarsky/social-app.git"
SOCIAL_APP_BRANCH="codex/torah-social-foundation"
STATE_ENV="${STATE_DIR}/torah-social.env"
INVITE_FILE="${STATE_DIR}/torah-social-invite-code.txt"

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

is_ipv4() {
  local ip="$1"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS='.' octet
  local -a octets
  read -r -a octets <<<"${ip}"
  for octet in "${octets[@]}"; do
    (( 10#${octet} >= 0 && 10#${octet} <= 255 )) || return 1
  done
}

# Preserve caller-provided overrides before loading saved state.
INPUT_ADMIN_EMAIL="${ADMIN_EMAIL:-}"
INPUT_PUBLIC_IP="${PUBLIC_IP:-}"
INPUT_APP_HOSTNAME="${APP_HOSTNAME:-}"
INPUT_PDS_HOSTNAME="${PDS_HOSTNAME:-}"

if [[ -f "${STATE_ENV}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_ENV}"
fi

ADMIN_EMAIL="${INPUT_ADMIN_EMAIL:-${ADMIN_EMAIL:-}}"
PUBLIC_IP="${INPUT_PUBLIC_IP:-${PUBLIC_IP:-}}"
APP_HOSTNAME="${INPUT_APP_HOSTNAME:-${APP_HOSTNAME:-}}"
PDS_HOSTNAME="${INPUT_PDS_HOSTNAME:-${PDS_HOSTNAME:-}}"

# A pristine cloud image may not contain curl/git/lsb_release yet. The official
# PDS installer needs lsb_release before it installs its own package list.
log "Preparing base system tools"
apt-get update
apt-get install --yes ca-certificates curl git lsb-release

if [[ -z "${PUBLIC_IP}" ]]; then
  log "Detecting public IPv4 address"
  PUBLIC_IP="$(curl --fail --silent --show-error --max-time 10 https://api.ipify.org || true)"
fi
is_ipv4 "${PUBLIC_IP}" || fail "Could not determine a public IPv4 address. Re-run with PUBLIC_IP=x.x.x.x"

IP_DASH="${PUBLIC_IP//./-}"
APP_HOSTNAME="${APP_HOSTNAME:-torah-${IP_DASH}.nip.io}"
PDS_HOSTNAME="${PDS_HOSTNAME:-pds-${IP_DASH}.nip.io}"

# A configured PDS cannot safely have its hostname changed just by rerunning
# this script. If one exists, its stored hostname is authoritative.
if [[ -f "${STATE_DIR}/pds.env" ]]; then
  EXISTING_PDS_HOSTNAME="$(sed -n 's/^PDS_HOSTNAME=//p' "${STATE_DIR}/pds.env" | head -n 1)"
  if [[ -n "${EXISTING_PDS_HOSTNAME}" && "${PDS_HOSTNAME}" != "${EXISTING_PDS_HOSTNAME}" ]]; then
    log "Preserving existing PDS hostname ${EXISTING_PDS_HOSTNAME}"
    PDS_HOSTNAME="${EXISTING_PDS_HOSTNAME}"
  fi
fi

if [[ -z "${ADMIN_EMAIL}" ]]; then
  fail "ADMIN_EMAIL is required on the first run, e.g. sudo ADMIN_EMAIL=you@example.com bash torah-social/install.sh"
fi

mkdir -p "${STATE_DIR}" "${TORAH_DIR}"
chmod 700 "${STATE_DIR}"
cat >"${STATE_ENV}" <<EOF
ADMIN_EMAIL=${ADMIN_EMAIL}
PUBLIC_IP=${PUBLIC_IP}
APP_HOSTNAME=${APP_HOSTNAME}
PDS_HOSTNAME=${PDS_HOSTNAME}
EOF
chmod 600 "${STATE_ENV}"

if [[ ! -f "${STATE_DIR}/pds.env" ]]; then
  log "Installing the official AT Protocol PDS stack"
  # The upstream installer asks at the end whether to create an account.
  # Account creation is intentionally handled through Torah Social instead.
  printf 'n\n' | bash "${REPO_ROOT}/installer.sh" "${STATE_DIR}" "${PDS_HOSTNAME}" "${ADMIN_EMAIL}"
else
  log "Existing PDS data found; preserving ${STATE_DIR}"
  systemctl enable pds >/dev/null 2>&1 || true
  systemctl restart pds
fi

# The current upstream installer writes the Caddy on-demand permission keyword
# as `task`; current Caddy uses `ask`. We write the complete intended config
# here and also add the Torah Social web hostname.
log "Configuring shared HTTPS for Torah Social and the PDS"
mkdir -p "${STATE_DIR}/caddy/data" "${STATE_DIR}/caddy/etc/caddy"
cat >"${STATE_DIR}/caddy/etc/caddy/Caddyfile" <<EOF
{
  email ${ADMIN_EMAIL}
  on_demand_tls {
    ask http://localhost:3000/tls-check
  }
}

${APP_HOSTNAME} {
  reverse_proxy http://127.0.0.1:8100
}

*.${PDS_HOSTNAME}, ${PDS_HOSTNAME} {
  tls {
    on_demand
  }
  reverse_proxy http://localhost:3000
}
EOF

log "Fetching Torah Social client"
if [[ ! -d "${SOCIAL_APP_DIR}/.git" ]]; then
  rm -rf "${SOCIAL_APP_DIR}"
  git clone --branch "${SOCIAL_APP_BRANCH}" --single-branch "${SOCIAL_APP_REPO}" "${SOCIAL_APP_DIR}"
else
  git -C "${SOCIAL_APP_DIR}" fetch origin "${SOCIAL_APP_BRANCH}"
  git -C "${SOCIAL_APP_DIR}" checkout "${SOCIAL_APP_BRANCH}"
  git -C "${SOCIAL_APP_DIR}" reset --hard "origin/${SOCIAL_APP_BRANCH}"
fi

BUNDLE_ID="$(git -C "${SOCIAL_APP_DIR}" rev-parse --short=12 HEAD)"
log "Building Torah Social web image (${BUNDLE_ID})"
docker build \
  --build-arg EXPO_PUBLIC_ENV=development \
  --build-arg EXPO_PUBLIC_BUNDLE_IDENTIFIER="${BUNDLE_ID}" \
  --build-arg EXPO_PUBLIC_TORAH_PDS_HOST="https://${PDS_HOSTNAME}" \
  --tag torah-social-web:latest \
  "${SOCIAL_APP_DIR}"

log "Starting Torah Social web"
docker rm --force torah-social-web >/dev/null 2>&1 || true
docker run --detach \
  --name torah-social-web \
  --restart unless-stopped \
  --publish 127.0.0.1:8100:8100 \
  --env ATP_APPVIEW_HOST=https://public.api.bsky.app \
  --env HTTP_ADDRESS=:8100 \
  --env ROBOTS_DISALLOW_ALL=true \
  torah-social-web:latest >/dev/null

# Reload/restart Caddy after the web listener exists. The PDS compose stack
# owns this container and will continue to restart it on boot.
if docker inspect caddy >/dev/null 2>&1; then
  docker restart caddy >/dev/null
else
  systemctl restart pds
fi

log "Waiting for the local PDS"
PDS_READY=0
for _ in $(seq 1 60); do
  if curl --fail --silent --max-time 2 http://127.0.0.1:3000/xrpc/_health >/dev/null 2>&1; then
    PDS_READY=1
    break
  fi
  sleep 2
done
[[ "${PDS_READY}" -eq 1 ]] || fail "PDS did not become healthy. Check: docker logs pds"

log "Waiting for public HTTPS"
HTTPS_READY=0
for _ in $(seq 1 45); do
  if curl --fail --silent --max-time 5 "https://${PDS_HOSTNAME}/xrpc/_health" >/dev/null 2>&1; then
    HTTPS_READY=1
    break
  fi
  sleep 2
done
[[ "${HTTPS_READY}" -eq 1 ]] || fail "HTTPS is not reachable yet. Make sure cloud firewall ports 80 and 443 are open."

log "Creating a one-use signup invite code"
if command -v pdsadmin >/dev/null 2>&1; then
  pdsadmin create-invite-code | tee "${INVITE_FILE}" >/dev/null
else
  PDS_ADMIN_PASSWORD="$(sed -n 's/^PDS_ADMIN_PASSWORD=//p' "${STATE_DIR}/pds.env")"
  curl --fail --silent --show-error \
    --request POST \
    --user "admin:${PDS_ADMIN_PASSWORD}" \
    --header 'Content-Type: application/json' \
    --data '{"useCount":1}' \
    "https://${PDS_HOSTNAME}/xrpc/com.atproto.server.createInviteCode" \
    | jq --raw-output '.code' | tee "${INVITE_FILE}" >/dev/null
fi
chmod 600 "${INVITE_FILE}"

# Ask the public relay to crawl this PDS. This is best-effort during the
# experimental phase; a failure here should not take down the local network.
if command -v pdsadmin >/dev/null 2>&1; then
  pdsadmin request-crawl >/dev/null 2>&1 || true
fi

INVITE_CODE="$(cat "${INVITE_FILE}")"

cat <<EOF

========================================================================
Torah Social experimental server is ready
========================================================================
Web:          https://${APP_HOSTNAME}
PDS:          https://${PDS_HOSTNAME}
Handle form:  username.${PDS_HOSTNAME}
Invite code:  ${INVITE_CODE}

Persistent PDS data: ${STATE_DIR}
Web source checkout: ${SOCIAL_APP_DIR}

Useful commands:
  docker logs -f torah-social-web
  docker logs -f pds
  docker logs -f caddy
  pdsadmin create-invite-code
========================================================================
EOF
