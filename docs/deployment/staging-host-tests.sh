#!/usr/bin/env bash
# Host-side staging tests. Run on the staging host after the first account was
# created. Credentials come from the environment and are never printed.
#
#   BASE_URL=https://staging.example.com ADMIN_EMAIL=... ADMIN_PASSWORD=... \
#   RELEASE_SHA=<full sha> RELEASE_IMAGE='ghcr.io/yuktastv/freellmapi:sha-...@sha256:...' \
#     ./staging-host-tests.sh /path/to/freellmapi-checkout
#
# Leaves Ollama emulation OFF and revokes every URL token it mints.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/lib.sh"; set +e
CHECKOUT="${1:?usage: staging-host-tests.sh <checkout>}"
: "${BASE_URL:?}"; : "${ADMIN_EMAIL:?}"; : "${ADMIN_PASSWORD:?}"; : "${RELEASE_SHA:?}"; : "${RELEASE_IMAGE:?}"
need curl python3 docker; FAILURES=0
PROJECT=freellmapi-staging
DIRECT=http://127.0.0.1:3001
cd "$CHECKOUT"
COMPOSE=(docker compose -p "$PROJECT" -f docker-compose.yml -f deploy/staging/docker-compose.staging.yml -f docker-compose.release.yml)
j() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@"; }

step "1. Dashboard authentication"
[ "$(code "$BASE_URL/api/keys")" = 401 ] && ok "admin API without a session -> 401" || fail "admin API without a session is not 401"
[ "$(code -X POST -H 'Content-Type: application/json' -d "$(python3 -c 'import json,os;print(json.dumps({"email":os.environ["ADMIN_EMAIL"],"password":"wrong-password-for-test"}))')" "$BASE_URL/api/auth/login")" = 401 ] && ok "wrong password -> 401" || fail "wrong password is not 401"
LOGIN_BODY="$(python3 -c 'import json,os;print(json.dumps({"email":os.environ["ADMIN_EMAIL"],"password":os.environ["ADMIN_PASSWORD"]}))')"
TOKEN="$(curl -s -X POST -H 'Content-Type: application/json' -d "$LOGIN_BODY" "$BASE_URL/api/auth/login" | j 'd.get("token","")')"
[ -n "$TOKEN" ] && ok "login succeeds" || { fail "login failed"; echo "cannot continue without a session"; exit 1; }
AUTH=(-H "Authorization: Bearer $TOKEN")
[ "$(code "${AUTH[@]}" "$BASE_URL/api/keys")" = 200 ] && ok "admin API with a session -> 200" || fail "admin API with a session is not 200"

step "2. API authentication and key-required Ollama"
APIKEY="$(curl -s "${AUTH[@]}" "$BASE_URL/api/settings/api-key" | j 'd.get("apiKey","")')"
[ -n "$APIKEY" ] || fail "could not read the unified API key"
[ "$(code "$BASE_URL/v1/models")" = 401 ] && ok "/v1 without a key -> 401" || fail "/v1 without a key is not 401"
[ "$(code -H "Authorization: Bearer $APIKEY" "$BASE_URL/v1/models")" = 200 ] && ok "/v1 with the unified key -> 200" || fail "/v1 with the key is not 200"
setmode() { curl -s -o /dev/null -X PUT "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"ollamaEmulation\":\"$1\"}" "$BASE_URL/api/settings/agent-compatibility"; }
MINT="$(curl -s -X POST "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"label":"release-test"}' "$BASE_URL/api/settings/url-tokens")"
UT="$(j 'd.get("token","")' <<<"$MINT")"; UTID="$(j 'd.get("id","")' <<<"$MINT")"
[ -n "$UT" ] && ok "URL token minted" || fail "could not mint a URL token"
setmode key-required
[ "$(code "$BASE_URL/api/tags")" = 401 ] && ok "key-required: /api/tags without a key -> 401" || fail "key-required without a key is not 401"
[ "$(code -H "Authorization: Bearer $APIKEY" "$BASE_URL/api/tags")" = 200 ] && ok "key-required: /api/tags with the key -> 200" || fail "key-required with the key is not 200"
[ "$(code "$BASE_URL/v1/t/$UT/api/tags")" = 200 ] && ok "key-required: URL token -> 200" || fail "key-required URL token is not 200"

step "3. Disabled Ollama routes return 404, URL tokens included"
setmode off
for p in /api/tags /api/version; do
  [ "$(code -H "Authorization: Bearer $APIKEY" "$BASE_URL$p")" = 404 ] && ok "off: $p -> 404" || fail "off: $p is not 404"
  [ "$(code "$BASE_URL/v1/t/$UT$p")" = 404 ] && ok "off: URL token $p -> 404" || fail "off: URL token $p is not 404"
done
[ "$(code -X POST -H 'Content-Type: application/json' -d '{"model":"auto","messages":[{"role":"user","content":"hi"}],"stream":false}' "$BASE_URL/v1/t/$UT/api/chat")" = 404 ] && ok "off: URL token /api/chat -> 404" || fail "off: URL token /api/chat is not 404"
[ "$(code "$BASE_URL/v1/t/$UT/models")" = 200 ] && ok "URL token still serves /models" || fail "URL token /models is not 200"

step "6. IPv6 rotation inside one /64 cannot bypass the rate limit"
# Directly against the container on the host: with TRUST_PROXY=1 the Docker
# gateway is the trusted hop, so X-Forwarded-For names the client.
P="2001:db8:$(printf '%x' $((RANDOM)))"; LIMIT=120; first429=0
for i in $(seq 1 $((LIMIT + 5))); do
  c="$(code -H "X-Forwarded-For: ${P}:1:2::$(printf '%x' "$i")" "$DIRECT/v1/models")"
  if [ "$c" = 429 ]; then first429=$i; break; fi
done
[ "$first429" -gt 0 ] && [ "$first429" -le $((LIMIT + 1)) ] && ok "rotating addresses in ${P}:1:2::/64 hit 429 at request $first429" || fail "no 429 within $((LIMIT + 5)) rotated requests (first429=$first429)"
[ "$(code -H "X-Forwarded-For: ${P}:1:3::1" "$DIRECT/v1/models")" != 429 ] && ok "a neighbouring /64 is not limited" || fail "neighbouring /64 was limited"

step "7. Update endpoints stay disabled"
[ "$(curl -s "${AUTH[@]}" "$BASE_URL/api/update/check" | j 'd.get("status")')" = disabled ] && ok "/api/update/check disabled" || fail "/api/update/check not disabled"
[ "$(curl -s "${AUTH[@]}" "$BASE_URL/api/update/status" | j 'd.get("status")')" = disabled ] && ok "/api/update/status disabled" || fail "/api/update/status not disabled"
r="$(curl -s -w ' %{http_code}' -X POST "${AUTH[@]}" "$BASE_URL/api/update/apply")"
case "$r" in *'"disabled"'*' 409') ok "/api/update/apply -> 409 disabled";; *) fail "/api/update/apply did not refuse: ${r##* }";; esac

step "8. Data survives a restart"
CID="$(container_of "$PROJECT")"
"${COMPOSE[@]}" restart freellmapi >/dev/null
CID="$(container_of "$PROJECT")"; wait_healthy "$CID" && ok "healthy after restart" || fail "not healthy after restart"
[ "$(code "${AUTH[@]}" "$BASE_URL/api/keys")" = 200 ] && ok "session survived the restart" || fail "session lost after restart"
curl -s "${AUTH[@]}" "$BASE_URL/api/settings/url-tokens" | grep -q "release-test" && ok "URL token survived the restart" || fail "URL token lost after restart"
[ "$(curl -s "${AUTH[@]}" "$BASE_URL/api/settings/api-key" | j 'd.get("apiKey","")')" = "$APIKEY" ] && ok "unified key unchanged (encryption key intact)" || fail "unified key changed after restart"

step "10. Running image and revision"
verify_running_image "$CID" "$RELEASE_IMAGE" "$RELEASE_SHA"

step "Cleanup"
[ -n "$UTID" ] && [ "$(code -X DELETE "${AUTH[@]}" "$BASE_URL/api/settings/url-tokens/$UTID")" = 204 ] && ok "test URL token revoked" || fail "could not revoke the test URL token"
setmode off; ok "Ollama emulation left OFF"
echo; [ "$FAILURES" = 0 ] && echo "All host-side staging tests passed." || { echo "$FAILURES host-side test(s) FAILED"; exit 1; }
