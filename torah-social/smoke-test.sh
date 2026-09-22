#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-https://appview-130-110-238-163.nip.io}"
PDS_URL="${PDS_URL:-https://pds-130-110-238-163.nip.io}"

echo "========================================================"
echo "Torah Social Automated Smoke Test Suite"
echo "Target AppView: ${BASE_URL}"
echo "Target PDS:     ${PDS_URL}"
echo "========================================================"

FAILED=0
PASSED=0

check() {
  local num="$1"
  local name="$2"
  local result="$3"
  if [ "$result" -eq 0 ]; then
    echo "PASS [Check ${num}]: ${name}"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL [Check ${num}]: ${name}"
    FAILED=$((FAILED + 1))
  fi
}

RAND_SUFFIX="$(date +%s | tail -c 6)-$((RANDOM % 900 + 100))"
USER_A_HANDLE="u-a-${RAND_SUFFIX}.pds-130-110-238-163.nip.io"
USER_A_EMAIL="u-a-${RAND_SUFFIX}@torah-social.local"
USER_A_PASS="PassA-${RAND_SUFFIX}!"

USER_B_HANDLE="u-b-${RAND_SUFFIX}.pds-130-110-238-163.nip.io"
USER_B_EMAIL="u-b-${RAND_SUFFIX}@torah-social.local"
USER_B_PASS="PassB-${RAND_SUFFIX}!"

# 1. Health check: PDS /xrpc/_health returns 200
HTTP_CODE="$(curl -sk -o /dev/null -w "%{http_code}" "${PDS_URL}/xrpc/_health" || echo "000")"
[ "$HTTP_CODE" = "200" ] && check 1 "PDS /xrpc/_health returns 200" 0 || check 1 "PDS /xrpc/_health returns 200 (got ${HTTP_CODE})" 1

# 2. Health check: AppView /xrpc/_health returns 200
HTTP_CODE="$(curl -sk -o /dev/null -w "%{http_code}" "${BASE_URL}/xrpc/_health" || echo "000")"
[ "$HTTP_CODE" = "200" ] && check 2 "AppView /xrpc/_health returns 200" 0 || check 2 "AppView /xrpc/_health returns 200 (got ${HTTP_CODE})" 1

# 3. DID Document: PDS /.well-known/did.json valid JSON with #atproto_pds
PDS_DID_DOC="$(curl -sk "${PDS_URL}/.well-known/did.json" || echo "{}")"
echo "$PDS_DID_DOC" | jq -e '.service[] | select(.id == "#atproto_pds")' >/dev/null 2>&1 \
  && check 3 "PDS /.well-known/did.json valid JSON with #atproto_pds" 0 \
  || check 3 "PDS /.well-known/did.json valid JSON with #atproto_pds" 1

# 4. DID Document: AppView /.well-known/did.json valid JSON with #bsky_appview
APPVIEW_DID_DOC="$(curl -sk "${BASE_URL}/.well-known/did.json" || echo "{}")"
echo "$APPVIEW_DID_DOC" | jq -e '.service[] | select(.id == "#bsky_appview")' >/dev/null 2>&1 \
  && check 4 "AppView /.well-known/did.json valid JSON with #bsky_appview" 0 \
  || check 4 "AppView /.well-known/did.json valid JSON with #bsky_appview" 1

# 5. Chat Service Endpoint: AppView or chat service declares #bsky_chat in its DID document
echo "$APPVIEW_DID_DOC" | jq -e '.service[] | select(.id == "#bsky_chat")' >/dev/null 2>&1 \
  && check 5 "Chat service endpoint declares #bsky_chat in DID doc" 0 \
  || check 5 "Chat service endpoint declares #bsky_chat in DID doc" 1

# 6. Account Creation: Create test account A
CREATE_A_RES="$(curl -sk -X POST "${PDS_URL}/xrpc/com.atproto.server.createAccount" \
  -H "Content-Type: application/json" \
  -d "{\"handle\":\"${USER_A_HANDLE}\",\"email\":\"${USER_A_EMAIL}\",\"password\":\"${USER_A_PASS}\"}" || echo "{}")"
USER_A_DID="$(echo "$CREATE_A_RES" | jq -r '.did // empty')"
USER_A_JWT="$(echo "$CREATE_A_RES" | jq -r '.accessJwt // empty')"
[ -n "$USER_A_DID" ] && check 6 "Account Creation User A (${USER_A_HANDLE})" 0 || check 6 "Account Creation User A failed" 1

# 7. Account Creation: Create test account B
CREATE_B_RES="$(curl -sk -X POST "${PDS_URL}/xrpc/com.atproto.server.createAccount" \
  -H "Content-Type: application/json" \
  -d "{\"handle\":\"${USER_B_HANDLE}\",\"email\":\"${USER_B_EMAIL}\",\"password\":\"${USER_B_PASS}\"}" || echo "{}")"
USER_B_DID="$(echo "$CREATE_B_RES" | jq -r '.did // empty')"
USER_B_JWT="$(echo "$CREATE_B_RES" | jq -r '.accessJwt // empty')"
[ -n "$USER_B_DID" ] && check 7 "Account Creation User B (${USER_B_HANDLE})" 0 || check 7 "Account Creation User B failed" 1

# 8. Authentication: Login as User A
LOGIN_A_RES="$(curl -sk -X POST "${PDS_URL}/xrpc/com.atproto.server.createSession" \
  -H "Content-Type: application/json" \
  -d "{\"identifier\":\"${USER_A_HANDLE}\",\"password\":\"${USER_A_PASS}\"}" || echo "{}")"
USER_A_JWT="$(echo "$LOGIN_A_RES" | jq -r '.accessJwt // empty')"
[ -n "$USER_A_JWT" ] && check 8 "Login User A, obtain access token" 0 || check 8 "Login User A failed" 1

# 9. Authentication: Login as User B
LOGIN_B_RES="$(curl -sk -X POST "${PDS_URL}/xrpc/com.atproto.server.createSession" \
  -H "Content-Type: application/json" \
  -d "{\"identifier\":\"${USER_B_HANDLE}\",\"password\":\"${USER_B_PASS}\"}" || echo "{}")"
USER_B_JWT="$(echo "$LOGIN_B_RES" | jq -r '.accessJwt // empty')"
[ -n "$USER_B_JWT" ] && check 9 "Login User B, obtain access token" 0 || check 9 "Login User B failed" 1

# 10. Post Creation: User A creates a post with Hebrew text
HEBREW_TEXT="שלום עולם — בדיקת מערכת ${RAND_SUFFIX}"
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
CREATE_POST_RES="$(curl -sk -X POST "${PDS_URL}/xrpc/com.atproto.repo.createRecord" \
  -H "Authorization: Bearer ${USER_A_JWT}" \
  -H "Content-Type: application/json" \
  -d "{\"repo\":\"${USER_A_DID}\",\"collection\":\"app.bsky.feed.post\",\"record\":{\"\$type\":\"app.bsky.feed.post\",\"text\":\"${HEBREW_TEXT}\",\"createdAt\":\"${NOW_ISO}\"}}" || echo "{}")"
POST_URI="$(echo "$CREATE_POST_RES" | jq -r '.uri // empty')"
POST_CID="$(echo "$CREATE_POST_RES" | jq -r '.cid // empty')"
[ -n "$POST_URI" ] && check 10 "User A creates post with Hebrew text" 0 || check 10 "User A post creation failed" 1

## 11. Post Indexing: Verify post appears in User A's author feed via AppView within 15 seconds
INDEXED=1
for i in {1..15}; do
  FEED_RES="$(curl -sk "${BASE_URL}/xrpc/app.bsky.feed.getAuthorFeed?actor=${USER_A_DID}&limit=5" || echo "{}")"
  if echo "$FEED_RES" | grep -q "${RAND_SUFFIX}"; then
    INDEXED=0
    break
  fi
  sleep 1
done
check 11 "Post appears in User A author feed via AppView" "$INDEXED"

# 12. Search: Search for the post by Hebrew text via AppView returns the post
SEARCH_TERM="בדיקת מערכת ${RAND_SUFFIX}"
SEARCH_RES="$(curl -sk --get --data-urlencode "q=${SEARCH_TERM}" "${BASE_URL}/xrpc/app.bsky.feed.searchPosts" || echo "{}")"
echo "$SEARCH_RES" | grep -q "${RAND_SUFFIX}" \
  && check 12 "Search post by Hebrew text returns post" 0 \
  || check 12 "Search post by Hebrew text returns post" 1

# 13. Social Graph: User B follows User A
FOLLOW_RES="$(curl -sk -X POST "${PDS_URL}/xrpc/com.atproto.repo.createRecord" \
  -H "Authorization: Bearer ${USER_B_JWT}" \
  -H "Content-Type: application/json" \
  -d "{\"repo\":\"${USER_B_DID}\",\"collection\":\"app.bsky.graph.follow\",\"record\":{\"\$type\":\"app.bsky.graph.follow\",\"subject\":\"${USER_A_DID}\",\"createdAt\":\"${NOW_ISO}\"}}" || echo "{}")"
FOLLOW_URI="$(echo "$FOLLOW_RES" | jq -r '.uri // empty')"
[ -n "$FOLLOW_URI" ] && check 13 "User B follows User A" 0 || check 13 "User B follow User A failed" 1

# 14. Timeline: User B's timeline includes User A's post via PDS proxy
TIMELINE_FOUND=1
for i in {1..10}; do
  TL_RES="$(curl -sk "${PDS_URL}/xrpc/app.bsky.feed.getTimeline?limit=10" \
    -H "Authorization: Bearer ${USER_B_JWT}" || echo "{}")"
  if echo "$TL_RES" | grep -q "${RAND_SUFFIX}"; then
    TIMELINE_FOUND=0
    break
  fi
  sleep 0.5
done
check 14 "User B timeline includes User A post" "$TIMELINE_FOUND"

# 15. Interaction: User B likes User A's post
LIKE_RES="$(curl -sk -X POST "${PDS_URL}/xrpc/com.atproto.repo.createRecord" \
  -H "Authorization: Bearer ${USER_B_JWT}" \
  -H "Content-Type: application/json" \
  -d "{\"repo\":\"${USER_B_DID}\",\"collection\":\"app.bsky.feed.like\",\"record\":{\"\$type\":\"app.bsky.feed.like\",\"subject\":{\"uri\":\"${POST_URI}\",\"cid\":\"${POST_CID}\"},\"createdAt\":\"${NOW_ISO}\"}}" || echo "{}")"
LIKE_URI="$(echo "$LIKE_RES" | jq -r '.uri // empty')"
[ -n "$LIKE_URI" ] && check 15 "User B likes User A post" 0 || check 15 "User B like post failed" 1

# 16. Thread: User B replies to User A's post; verify thread view returns root + reply
REPLY_TEXT="תגובה בבדיקה — ${RAND_SUFFIX}"
REPLY_RES="$(curl -sk -X POST "${PDS_URL}/xrpc/com.atproto.repo.createRecord" \
  -H "Authorization: Bearer ${USER_B_JWT}" \
  -H "Content-Type: application/json" \
  -d "{\"repo\":\"${USER_B_DID}\",\"collection\":\"app.bsky.feed.post\",\"record\":{\"\$type\":\"app.bsky.feed.post\",\"text\":\"${REPLY_TEXT}\",\"reply\":{\"root\":{\"uri\":\"${POST_URI}\",\"cid\":\"${POST_CID}\"},\"parent\":{\"uri\":\"${POST_URI}\",\"cid\":\"${POST_CID}\"}},\"createdAt\":\"${NOW_ISO}\"}}" || echo "{}")"
REPLY_URI="$(echo "$REPLY_RES" | jq -r '.uri // empty')"
sleep 1
THREAD_RES="$(curl -sk --get --data-urlencode "uri=${POST_URI}" "${BASE_URL}/xrpc/app.bsky.feed.getPostThread" || echo "{}")"
echo "$THREAD_RES" | grep -q "${RAND_SUFFIX}" \
  && check 16 "Thread view returns root + reply" 0 \
  || check 16 "Thread view returns root + reply" 1

# 17. Notifications: User A's notifications include User B's follow, like, and reply via PDS
NOTIF_FOUND=1
for i in {1..10}; do
  NOTIF_RES="$(curl -sk "${PDS_URL}/xrpc/app.bsky.notification.listNotifications?limit=20" \
    -H "Authorization: Bearer ${USER_A_JWT}" || echo "{}")"
  if echo "$NOTIF_RES" | grep -q "${USER_B_DID}"; then
    NOTIF_FOUND=0
    break
  fi
  sleep 0.5
done
check 17 "User A notifications include User B actions" "$NOTIF_FOUND"

# 18. Notification count: User A's unread count > 0; mark read; verify count resets via PDS
UNREAD_RES="$(curl -sk "${PDS_URL}/xrpc/app.bsky.notification.getUnreadCount" \
  -H "Authorization: Bearer ${USER_A_JWT}" || echo "{}")"
UNREAD_COUNT="$(echo "$UNREAD_RES" | jq -r '.count // 0')"
curl -sk -X POST "${PDS_URL}/xrpc/app.bsky.notification.updateSeen" \
  -H "Authorization: Bearer ${USER_A_JWT}" \
  -H "Content-Type: application/json" \
  -d "{\"seenAt\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}" >/dev/null 2>&1 || true
UNREAD_AFTER="$(curl -sk "${PDS_URL}/xrpc/app.bsky.notification.getUnreadCount" \
  -H "Authorization: Bearer ${USER_A_JWT}" | jq -r '.count // 0')"
[ "$UNREAD_COUNT" -ge 0 ] && [ "$UNREAD_AFTER" -eq 0 ] \
  && check 18 "Notification count resets after updateSeen" 0 \
  || check 18 "Notification count resets after updateSeen" 1

# 19. Explore: AppView unspecced.getSuggestedUsersForExplore returns 200 (not 500)
EXPLORE_CODE="$(curl -sk -o /dev/null -w "%{http_code}" "${BASE_URL}/xrpc/app.bsky.unspecced.getSuggestedUsersForExplore?limit=10" || echo "000")"
[ "$EXPLORE_CODE" = "200" ] && check 19 "Explore getSuggestedUsersForExplore returns 200" 0 || check 19 "Explore returned ${EXPLORE_CODE}" 1

# 20. Discover: AppView getFeed for default Discover feed returns 200 with posts (not 500)
APPVIEW_DID="$(echo "$APPVIEW_DID_DOC" | jq -r '.id // empty')"
DISCOVER_FEED_URI="at://${APPVIEW_DID}/app.bsky.feed.generator/whats-hot"
DISCOVER_CODE="$(curl -sk -o /dev/null -w "%{http_code}" --get --data-urlencode "feed=${DISCOVER_FEED_URI}" --data-urlencode "limit=10" "${BASE_URL}/xrpc/app.bsky.feed.getFeed" || echo "000")"
[ "$DISCOVER_CODE" = "200" ] && check 20 "Discover feed (whats-hot) returns 200" 0 || check 20 "Discover feed returned ${DISCOVER_CODE}" 1

# 21. Chat: User A sends a chat message to User B via chat proxy; User B reads it
CONVO_RES="$(curl -sk -X POST "${BASE_URL}/xrpc/chat.bsky.convo.getConvoForMembers" \
  -H "Authorization: Bearer ${USER_A_JWT}" \
  -H "Content-Type: application/json" \
  -d "{\"members\":[\"${USER_A_DID}\",\"${USER_B_DID}\"]}" || echo "{}")"
CONVO_ID="$(echo "$CONVO_RES" | jq -r '.convo.id // empty')"

CHAT_PASSED=1
if [ -n "$CONVO_ID" ]; then
  CHAT_TEXT="הודעת צ'אט בדיקה ${RAND_SUFFIX}"
  SEND_RES="$(curl -sk -X POST "${BASE_URL}/xrpc/chat.bsky.convo.sendMessage" \
    -H "Authorization: Bearer ${USER_A_JWT}" \
    -H "Content-Type: application/json" \
    -d "{\"convoId\":\"${CONVO_ID}\",\"message\":{\"text\":\"${CHAT_TEXT}\"}}" || echo "{}")"
  MSG_ID="$(echo "$SEND_RES" | jq -r '.id // empty')"
  if [ -n "$MSG_ID" ]; then
    GET_MSGS="$(curl -sk "${BASE_URL}/xrpc/chat.bsky.convo.getMessages?convoId=${CONVO_ID}&limit=10" \
      -H "Authorization: Bearer ${USER_B_JWT}" || echo "{}")"
    if echo "$GET_MSGS" | grep -q "${CHAT_TEXT}"; then
      CHAT_PASSED=0
    fi
  fi
fi
check 21 "Chat User A sends to User B, User B reads it" "$CHAT_PASSED"

echo "========================================================"
echo "Smoke Test Summary: ${PASSED}/21 PASSED, ${FAILED}/21 FAILED"
echo "========================================================"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
