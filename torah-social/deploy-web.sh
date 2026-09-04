#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run with sudo/root." >&2
  exit 1
fi

STATE_DIR="/pds"
TORAH_ENV="${STATE_DIR}/torah-social.env"
APPVIEW_INFO="${STATE_DIR}/torah-appview-info"
SOCIAL_APP_DIR="/opt/torah-social/social-app"
SOCIAL_APP_REPO="https://github.com/davidpovarsky/social-app.git"
SOCIAL_APP_BRANCH="codex/torah-social-foundation"

log(){ printf '\n==> %s\n' "$*"; }
fail(){ echo "ERROR: $*" >&2; exit 1; }

[[ -f "${TORAH_ENV}" ]] || fail "Missing ${TORAH_ENV}."
[[ -f "${APPVIEW_INFO}" ]] || fail "Missing ${APPVIEW_INFO}; AppView must be installed first."
# shellcheck disable=SC1090
source "${TORAH_ENV}"
# shellcheck disable=SC1090
source "${APPVIEW_INFO}"

[[ -n "${APP_HOSTNAME:-}" ]] || fail "APP_HOSTNAME missing from ${TORAH_ENV}."
[[ -n "${PDS_HOSTNAME:-}" ]] || fail "PDS_HOSTNAME missing from ${TORAH_ENV}."
[[ -n "${APPVIEW_HOSTNAME:-}" ]] || fail "APPVIEW_HOSTNAME missing from ${APPVIEW_INFO}."
[[ -n "${APPVIEW_DID:-}" ]] || fail "APPVIEW_DID missing from ${APPVIEW_INFO}."

PDS_DID="did:web:${PDS_HOSTNAME}"

log "Fetching latest Torah Social client"
if [[ ! -d "${SOCIAL_APP_DIR}/.git" ]]; then
  rm -rf "${SOCIAL_APP_DIR}"
  git clone --branch "${SOCIAL_APP_BRANCH}" --single-branch "${SOCIAL_APP_REPO}" "${SOCIAL_APP_DIR}"
else
  git -C "${SOCIAL_APP_DIR}" fetch origin "${SOCIAL_APP_BRANCH}"
  git -C "${SOCIAL_APP_DIR}" checkout "${SOCIAL_APP_BRANCH}"
  git -C "${SOCIAL_APP_DIR}" reset --hard "origin/${SOCIAL_APP_BRANCH}"
fi

BUNDLE_ID="$(git -C "${SOCIAL_APP_DIR}" rev-parse --short=12 HEAD)"
FULL_COMMIT="$(git -C "${SOCIAL_APP_DIR}" rev-parse HEAD)"
log "Building isolated Torah Social web bundle (${BUNDLE_ID})"

docker build \
  --build-arg EXPO_PUBLIC_ENV=development \
  --build-arg EXPO_PUBLIC_BUNDLE_IDENTIFIER="${BUNDLE_ID}" \
  --build-arg EXPO_PUBLIC_TORAH_PDS_HOST="https://${PDS_HOSTNAME}" \
  --build-arg EXPO_PUBLIC_TORAH_PDS_DID="${PDS_DID}" \
  --build-arg EXPO_PUBLIC_TORAH_APPVIEW_HOST="https://${APPVIEW_HOSTNAME}" \
  --build-arg EXPO_PUBLIC_BLUESKY_PROXY_DID="${APPVIEW_DID}" \
  --build-arg EXPO_PUBLIC_TORAH_ISOLATED_NETWORK=true \
  --tag "torah-social-web:${BUNDLE_ID}" \
  --tag torah-social-web:latest \
  "${SOCIAL_APP_DIR}"

log "Replacing Torah Social web container"
docker rm --force torah-social-web >/dev/null 2>&1 || true

docker run --detach \
  --name torah-social-web \
  --restart unless-stopped \
  --publish 127.0.0.1:8100:8100 \
  --env "ATP_APPVIEW_HOST=https://${APPVIEW_HOSTNAME}" \
  --env HTTP_ADDRESS=:8100 \
  --env ROBOTS_DISALLOW_ALL=true \
  torah-social-web:latest >/dev/null

log "Checking local web health"
LOCAL_READY=0
for _ in $(seq 1 45); do
  if curl --fail --silent --max-time 3 http://127.0.0.1:8100/ >/dev/null 2>&1; then
    LOCAL_READY=1
    break
  fi
  sleep 2
done
[[ "${LOCAL_READY}" -eq 1 ]] || {
  docker logs --tail 160 torah-social-web >&2 || true
  fail "Torah Social web did not become healthy locally."
}

log "Checking public HTTPS"
PUBLIC_READY=0
for _ in $(seq 1 45); do
  if curl --fail --silent --max-time 5 "https://${APP_HOSTNAME}/" >/dev/null 2>&1; then
    PUBLIC_READY=1
    break
  fi
  sleep 2
done
[[ "${PUBLIC_READY}" -eq 1 ]] || {
  docker logs --tail 120 caddy >&2 || true
  fail "Public Torah Social HTTPS did not become healthy."
}

python3 - "${APPVIEW_INFO}" "${BUNDLE_ID}" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
bundle = sys.argv[2]
lines = path.read_text().splitlines()
out = []
seen = False
for line in lines:
    if line.startswith('CLIENT_BUNDLE='):
        out.append(f'CLIENT_BUNDLE={bundle}')
        seen = True
    else:
        out.append(line)
if not seen:
    out.append(f'CLIENT_BUNDLE={bundle}')
path.write_text('\n'.join(out) + '\n')
PY
chmod 600 "${APPVIEW_INFO}"
printf '%s\n' "${FULL_COMMIT}" > "${STATE_DIR}/torah-social-web-commit"
chmod 600 "${STATE_DIR}/torah-social-web-commit"

cat <<EOF

========================================================================
Torah Social Web deployment COMPLETE
========================================================================
Web:        https://${APP_HOSTNAME}
PDS:        https://${PDS_HOSTNAME}
AppView:    https://${APPVIEW_HOSTNAME}
Client SHA: ${FULL_COMMIT}
Bundle:     ${BUNDLE_ID}
Isolation:  true
========================================================================
EOF
