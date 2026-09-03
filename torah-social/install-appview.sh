#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run with sudo/root." >&2
  exit 1
fi

STATE_DIR="/pds"
TORAH_ENV="${STATE_DIR}/torah-social.env"
APPVIEW_ENV="${STATE_DIR}/torah-appview.env"
APPVIEW_DB_DIR="${STATE_DIR}/torah-appview-postgres"
APPVIEW_SRC_DIR="/opt/torah-appview/atproto"
SOCIAL_APP_DIR="/opt/torah-social/social-app"
ATPROTO_REPO="https://github.com/davidpovarsky/atproto.git"
ATPROTO_BRANCH="codex/torah-social-foundation"
SOCIAL_APP_REPO="https://github.com/davidpovarsky/social-app.git"
SOCIAL_APP_BRANCH="codex/torah-social-foundation"
DEPLOY_VERSION="client-isolation-v2"

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -f "${TORAH_ENV}" ]] || fail "Missing ${TORAH_ENV}; run the Torah Social base installer first."
# shellcheck disable=SC1090
source "${TORAH_ENV}"

[[ -n "${PUBLIC_IP:-}" ]] || fail "PUBLIC_IP missing from ${TORAH_ENV}"
[[ -n "${APP_HOSTNAME:-}" ]] || fail "APP_HOSTNAME missing from ${TORAH_ENV}"
[[ -n "${PDS_HOSTNAME:-}" ]] || fail "PDS_HOSTNAME missing from ${TORAH_ENV}"
[[ -n "${ADMIN_EMAIL:-}" ]] || fail "ADMIN_EMAIL missing from ${TORAH_ENV}"

IP_DASH="${PUBLIC_IP//./-}"
APPVIEW_HOSTNAME="appview-${IP_DASH}.nip.io"
PDS_DID="did:web:${PDS_HOSTNAME}"

log "Preparing persistent Torah AppView secrets"
mkdir -p "${APPVIEW_DB_DIR}" "$(dirname "${APPVIEW_SRC_DIR}")" "$(dirname "${SOCIAL_APP_DIR}")"
if [[ ! -f "${APPVIEW_ENV}" ]]; then
  umask 077
  cat >"${APPVIEW_ENV}" <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 24)
APPVIEW_SIGNING_KEY=$(openssl rand -hex 32)
APPVIEW_ADMIN_PASSWORD=$(openssl rand -hex 24)
BSYNC_API_KEY=$(openssl rand -hex 24)
EOF
fi
chmod 600 "${APPVIEW_ENV}"
# shellcheck disable=SC1090
source "${APPVIEW_ENV}"

log "Fetching the Torah Social atproto fork"
if [[ ! -d "${APPVIEW_SRC_DIR}/.git" ]]; then
  rm -rf "${APPVIEW_SRC_DIR}"
  git clone --branch "${ATPROTO_BRANCH}" --single-branch "${ATPROTO_REPO}" "${APPVIEW_SRC_DIR}"
else
  git -C "${APPVIEW_SRC_DIR}" fetch origin "${ATPROTO_BRANCH}"
  git -C "${APPVIEW_SRC_DIR}" checkout "${ATPROTO_BRANCH}"
  git -C "${APPVIEW_SRC_DIR}" reset --hard "origin/${ATPROTO_BRANCH}"
fi

log "Building the isolated Torah AppView image"
docker build \
  --file "${APPVIEW_SRC_DIR}/services/torah-appview/Dockerfile" \
  --tag torah-appview:latest \
  "${APPVIEW_SRC_DIR}"

log "Starting persistent PostgreSQL for the Torah AppView"
docker rm --force torah-appview-postgres >/dev/null 2>&1 || true
docker run --detach \
  --name torah-appview-postgres \
  --restart unless-stopped \
  --publish 127.0.0.1:5432:5432 \
  --volume "${APPVIEW_DB_DIR}:/var/lib/postgresql/data" \
  --env POSTGRES_DB=torah_appview \
  --env POSTGRES_USER=torah \
  --env "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" \
  postgres:16-alpine >/dev/null

POSTGRES_READY=0
for _ in $(seq 1 60); do
  if docker exec torah-appview-postgres pg_isready -U torah -d torah_appview >/dev/null 2>&1; then
    POSTGRES_READY=1
    break
  fi
  sleep 2
done
[[ "${POSTGRES_READY}" -eq 1 ]] || fail "PostgreSQL did not become ready."

log "Deriving the stable AppView DID"
APPVIEW_DID="$(docker run --rm \
  --env "TORAH_KEY=${APPVIEW_SIGNING_KEY}" \
  torah-appview:latest \
  node --input-type=module -e \
  'import { Secp256k1Keypair } from "@atproto/crypto"; const k=await Secp256k1Keypair.import(process.env.TORAH_KEY); console.log(k.did())')"
[[ "${APPVIEW_DID}" == did:key:* ]] || fail "Could not derive AppView DID."
echo "AppView DID: ${APPVIEW_DID}"

log "Starting Torah Social AppView, dataplane, bsync, and PDS-only indexer"
docker rm --force torah-appview >/dev/null 2>&1 || true
docker run --detach \
  --name torah-appview \
  --restart unless-stopped \
  --network host \
  --env "TORAH_APPVIEW_DB_URL=postgresql://torah:${POSTGRES_PASSWORD}@127.0.0.1:5432/torah_appview" \
  --env "TORAH_APPVIEW_PUBLIC_URL=https://${APPVIEW_HOSTNAME}" \
  --env TORAH_APPVIEW_REPO_PROVIDER=ws://127.0.0.1:3000 \
  --env "TORAH_APPVIEW_SIGNING_KEY=${APPVIEW_SIGNING_KEY}" \
  --env "TORAH_APPVIEW_ADMIN_PASSWORD=${APPVIEW_ADMIN_PASSWORD}" \
  --env "TORAH_APPVIEW_BSYNC_API_KEY=${BSYNC_API_KEY}" \
  --env TORAH_APPVIEW_PLC_URL=https://plc.directory \
  torah-appview:latest >/dev/null

APPVIEW_LOCAL_READY=0
for _ in $(seq 1 90); do
  if curl --fail --silent --max-time 3 http://127.0.0.1:2584/xrpc/_health >/dev/null 2>&1; then
    APPVIEW_LOCAL_READY=1
    break
  fi
  if ! docker inspect --format '{{.State.Running}}' torah-appview 2>/dev/null | grep -q true; then
    docker logs --tail 120 torah-appview >&2 || true
    fail "Torah AppView container stopped during startup."
  fi
  sleep 2
done
if [[ "${APPVIEW_LOCAL_READY}" -ne 1 ]]; then
  docker logs --tail 160 torah-appview >&2 || true
  fail "Torah AppView did not become healthy locally."
fi

log "Publishing the Torah AppView through Caddy"
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

${APPVIEW_HOSTNAME} {
  reverse_proxy http://127.0.0.1:2584
}

*.${PDS_HOSTNAME}, ${PDS_HOSTNAME} {
  tls {
    on_demand
  }
  reverse_proxy http://localhost:3000
}
EOF

docker restart caddy >/dev/null

APPVIEW_HTTPS_READY=0
for _ in $(seq 1 45); do
  if curl --fail --silent --max-time 5 "https://${APPVIEW_HOSTNAME}/xrpc/_health" >/dev/null 2>&1; then
    APPVIEW_HTTPS_READY=1
    break
  fi
  sleep 2
done
[[ "${APPVIEW_HTTPS_READY}" -eq 1 ]] || {
  docker logs --tail 100 caddy >&2 || true
  fail "Public Torah AppView HTTPS did not become ready."
}

log "Pointing the PDS at our AppView and disconnecting Bluesky services"
python3 - "${STATE_DIR}/pds.env" "https://${APPVIEW_HOSTNAME}" "${APPVIEW_DID}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
appview_url = sys.argv[2]
appview_did = sys.argv[3]
updates = {
    'PDS_BSKY_APP_VIEW_URL': appview_url,
    'PDS_BSKY_APP_VIEW_DID': appview_did,
    'PDS_CRAWLERS': '',
    'PDS_MOD_SERVICE_URL': '',
    'PDS_MOD_SERVICE_DID': '',
    'PDS_REPORT_SERVICE_URL': '',
    'PDS_REPORT_SERVICE_DID': '',
}
lines = path.read_text().splitlines()
seen = set()
out = []
for line in lines:
    key = line.split('=', 1)[0] if '=' in line else None
    if key in updates:
        out.append(f'{key}={updates[key]}')
        seen.add(key)
    else:
        out.append(line)
for key, value in updates.items():
    if key not in seen:
        out.append(f'{key}={value}')
path.write_text('\n'.join(out) + '\n')
PY
chmod 600 "${STATE_DIR}/pds.env"
systemctl restart pds

PDS_READY=0
for _ in $(seq 1 60); do
  if curl --fail --silent --max-time 3 http://127.0.0.1:3000/xrpc/_health >/dev/null 2>&1; then
    PDS_READY=1
    break
  fi
  sleep 2
done
[[ "${PDS_READY}" -eq 1 ]] || fail "PDS did not recover after AppView reconfiguration."

# IMPORTANT: the React/Expo client contains public Bluesky AppView and Discover
# endpoints as compile-time constants. Merely changing ATP_APPVIEW_HOST on the
# bskyweb Go process does NOT change those values. Fetch the latest client and
# rebuild the static JS bundle with the local PDS/AppView baked into it.
log "Fetching the latest Torah Social client"
if [[ ! -d "${SOCIAL_APP_DIR}/.git" ]]; then
  rm -rf "${SOCIAL_APP_DIR}"
  git clone --branch "${SOCIAL_APP_BRANCH}" --single-branch "${SOCIAL_APP_REPO}" "${SOCIAL_APP_DIR}"
else
  git -C "${SOCIAL_APP_DIR}" fetch origin "${SOCIAL_APP_BRANCH}"
  git -C "${SOCIAL_APP_DIR}" checkout "${SOCIAL_APP_BRANCH}"
  git -C "${SOCIAL_APP_DIR}" reset --hard "origin/${SOCIAL_APP_BRANCH}"
fi

BUNDLE_ID="$(git -C "${SOCIAL_APP_DIR}" rev-parse --short=12 HEAD)"
log "Rebuilding Torah Social web bundle in isolated mode (${BUNDLE_ID})"
docker build \
  --build-arg EXPO_PUBLIC_ENV=development \
  --build-arg EXPO_PUBLIC_BUNDLE_IDENTIFIER="${BUNDLE_ID}" \
  --build-arg EXPO_PUBLIC_TORAH_PDS_HOST="https://${PDS_HOSTNAME}" \
  --build-arg EXPO_PUBLIC_TORAH_PDS_DID="${PDS_DID}" \
  --build-arg EXPO_PUBLIC_TORAH_APPVIEW_HOST="https://${APPVIEW_HOSTNAME}" \
  --build-arg EXPO_PUBLIC_BLUESKY_PROXY_DID="${APPVIEW_DID}" \
  --build-arg EXPO_PUBLIC_TORAH_ISOLATED_NETWORK=true \
  --tag torah-social-web:latest \
  "${SOCIAL_APP_DIR}"

log "Starting rebuilt Torah Social web against our AppView"
docker rm --force torah-social-web >/dev/null 2>&1 || true
docker run --detach \
  --name torah-social-web \
  --restart unless-stopped \
  --publish 127.0.0.1:8100:8100 \
  --env "ATP_APPVIEW_HOST=https://${APPVIEW_HOSTNAME}" \
  --env HTTP_ADDRESS=:8100 \
  --env ROBOTS_DISALLOW_ALL=true \
  torah-social-web:latest >/dev/null

WEB_READY=0
for _ in $(seq 1 45); do
  if curl --fail --silent --max-time 5 "https://${APP_HOSTNAME}/" >/dev/null 2>&1; then
    WEB_READY=1
    break
  fi
  sleep 2
done
[[ "${WEB_READY}" -eq 1 ]] || fail "Torah Social Web did not come back after the isolated rebuild."

cat >"${STATE_DIR}/torah-appview-info" <<EOF
APPVIEW_HOSTNAME=${APPVIEW_HOSTNAME}
APPVIEW_URL=https://${APPVIEW_HOSTNAME}
APPVIEW_DID=${APPVIEW_DID}
REPO_PROVIDER=ws://127.0.0.1:3000
CLIENT_BUNDLE=${BUNDLE_ID}
CLIENT_ISOLATED=true
EOF
chmod 600 "${STATE_DIR}/torah-appview-info"
printf '%s\n' "${DEPLOY_VERSION}" >"${STATE_DIR}/torah-appview-deploy-version"
chmod 600 "${STATE_DIR}/torah-appview-deploy-version"

cat <<EOF

========================================================================
Torah Social is now disconnected from the public Bluesky content network
========================================================================
Web:       https://${APP_HOSTNAME}
PDS:       https://${PDS_HOSTNAME}
AppView:   https://${APPVIEW_HOSTNAME}
AppView DID: ${APPVIEW_DID}
Indexed source: local Torah Social PDS ONLY
Public Bluesky crawler: DISABLED
Bluesky moderation/report services: DISABLED
Web client public AppView: REPLACED WITH TORAH APPVIEW
Web client public Discover feed: DISABLED/LOCALIZED
Client bundle: ${BUNDLE_ID}

The AppView database indexes only accounts/posts emitted by this Torah Social PDS.
========================================================================
EOF
