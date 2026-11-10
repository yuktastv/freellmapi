#!/usr/bin/env bash
# Switch an EXISTING production install to the verified fork release.
# Run on the production host, in the existing install directory, after it has
# been switched to a checkout of the fork at the release commit (keep .env:
# it is untracked and holds ENCRYPTION_KEY).
#
#   RELEASE_SHA=<full sha> RELEASE_IMAGE='ghcr.io/yuktastv/freellmapi:sha-...@sha256:...' \
#   PROD_PROJECT=<existing compose project name> BASE_URL=https://llm.example.com \
#   [DRY_RUN=1] ./prod-deploy.sh /path/to/existing/install
#
# Order: identify what runs -> read-only migration check (refuses a downgrade)
# -> stop + verified backup of volume and .env -> switch -> verify -> smoke
# tests. DRY_RUN=1 stops after the read-only checks and changes nothing.
# Writes rollback.env next to the backup for rollback.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/lib.sh"
DIR="${1:?usage: prod-deploy.sh <install dir>}"
: "${RELEASE_SHA:?}"; : "${RELEASE_IMAGE:?}"; : "${PROD_PROJECT:?set PROD_PROJECT to the EXISTING compose project name}"; : "${BASE_URL:?}"
need docker git sha256sum tar curl python3; need_compose
cd "$DIR"

step "1. Identify the running install"
CID="$(container_of "$PROD_PROJECT")"; [ -n "$CID" ] || die "no running freellmapi container in project '$PROD_PROJECT'"
PREV_IMAGE_ID="$(docker inspect --format '{{.Image}}' "$CID")"
PREV_REF="$(docker inspect --format '{{.Config.Image}}' "$CID")"
PREV_DIGEST="$(docker image inspect --format '{{index .RepoDigests 0}}' "$PREV_IMAGE_ID" 2>/dev/null || true)"
PREV_REV="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$PREV_IMAGE_ID")"
PREV_VER="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$PREV_IMAGE_ID")"
VOLUME="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/app/server/data"}}{{.Name}}{{end}}{{end}}' "$CID")"
echo "  running: $PREV_REF  digest=${PREV_DIGEST:-<none>}  revision=${PREV_REV:-<none>}  version=${PREV_VER:-<none>}"
echo "  volume:  $VOLUME"
[ -n "$VOLUME" ] || die "could not find the data volume"
[ "$VOLUME" = "${PROD_PROJECT}_freellmapi-data" ] || die "volume '$VOLUME' does not match project '$PROD_PROJECT': wrong project name would start an EMPTY database"
[ -n "$PREV_DIGEST" ] || die "the running image has no registry digest; rollback could not pull it back. Tag/push it or record it before continuing"
[ "$PREV_REV" = "$RELEASE_SHA" ] && die "production already runs the release revision"
env_has ENCRYPTION_KEY || die "no ENCRYPTION_KEY in $DIR/.env: refusing (stored provider keys would be undecryptable)"
KEY_BEFORE="$(key_hash)"

step "2. Release checkout"
[ "$(git rev-parse HEAD)" = "$RELEASE_SHA" ] || die "install dir is at $(git rev-parse --short HEAD), not the release ${RELEASE_SHA:0:7}"
git remote get-url origin | grep -q 'yuktastv/freellmapi' || die "install dir origin is not the fork"
case "$RELEASE_IMAGE" in ghcr.io/yuktastv/freellmapi:sha-"${RELEASE_SHA:0:7}"@sha256:*) ok "release image $RELEASE_IMAGE";; *) die "bad RELEASE_IMAGE";; esac

step "3. Database compatibility (read-only)"
migration_check "$CID" "$DIR" || die "database has migrations this release does not know: REFUSING an unsafe downgrade"
ok "no unknown migrations"

step "4. Configuration (appended only when missing; ENCRYPTION_KEY never touched)"
for kv in "FREELLMAPI_IMAGE_TAG=sha-${RELEASE_SHA:0:7}" "TRUST_PROXY=1" "DISABLE_LOCAL_TRUST=true" "FREELLMAPI_UPDATE_CHECK=off"; do
  k="${kv%%=*}"; v="${kv#*=}"
  if env_has "$k" && [ "$(env_get "$k")" != "$v" ]; then die ".env sets $k='$(env_get "$k")', expected '$v': fix it deliberately, then re-run"; fi
done
for k in FREELLMAPI_SELF_UPDATE_URL WATCHTOWER_TOKEN; do
  env_has "$k" && [ -n "$(env_get "$k" 2>/dev/null)" ] && die ".env enables self-update ($k): automatic updates must stay off"
done
HB="$(env_get HOST_BIND 2>/dev/null || true)"; [ -z "$HB" ] || [ "$HB" = 127.0.0.1 ] || die "HOST_BIND=$HB: the app port must stay on 127.0.0.1 behind nginx"
ok "configuration consistent"

if [ "${DRY_RUN:-0}" = 1 ]; then echo; echo "DRY_RUN: read-only checks passed. Nothing was changed."; exit 0; fi

step "5. Backup (container stops here)"
BK="$HOME/freellmapi-backups/prod-$(date -u +%Y%m%dT%H%M%SZ)"
backup_install "$CID" "$VOLUME" "$BK"; ok "volume + .env backed up and verified: $BK"
cat > "$BK/rollback.env" <<EOF
PROD_PROJECT=$PROD_PROJECT
VOLUME=$VOLUME
PREV_DIGEST=$PREV_DIGEST
PREV_REVISION=$PREV_REV
BACKUP_DIR=$BK
EOF
chmod 600 "$BK/rollback.env"

step "6. Switch"
for kv in "FREELLMAPI_IMAGE_TAG=sha-${RELEASE_SHA:0:7}" "TRUST_PROXY=1" "DISABLE_LOCAL_TRUST=true" "FREELLMAPI_UPDATE_CHECK=off"; do env_append "${kv%%=*}" "${kv#*=}"; done
cat > docker-compose.release.yml <<EOF
services:
  freellmapi:
    image: ${RELEASE_IMAGE}
    build: !reset null
EOF
COMPOSE=(docker compose -p "$PROD_PROJECT" -f docker-compose.yml -f docker-compose.release.yml)
cfg="$("${COMPOSE[@]}" config)"
grep -q "image: ${RELEASE_IMAGE}" <<<"$cfg" || die "rendered config does not use the release image"
grep -qF "name: ${VOLUME}" <<<"$cfg" || die "rendered config would not use volume $VOLUME"
grep -q 'host_ip: 127.0.0.1' <<<"$cfg" || die "port would not be bound to 127.0.0.1"
"${COMPOSE[@]}" pull freellmapi
docker rm -f "$CID" >/dev/null                 # the stopped old container; the volume is untouched
"${COMPOSE[@]}" up -d freellmapi               # never --profile autoupdate
NEW="$(container_of "$PROD_PROJECT")"; [ -n "$NEW" ] || die "new container did not start: run rollback.sh $BK"
wait_healthy "$NEW" && ok "healthy" || { docker logs --tail 80 "$NEW"; die "not healthy: run rollback.sh $BK"; }

step "7. Verify"
FAILURES=0
verify_running_image "$NEW" "$RELEASE_IMAGE" "$RELEASE_SHA"
[ "$(key_hash)" = "$KEY_BEFORE" ] && ok "ENCRYPTION_KEY unchanged" || fail "ENCRYPTION_KEY changed"
docker ps --format '{{.Names}}' | grep -q watchtower && fail "a watchtower container is running" || ok "no watchtower running"
if docker logs "$NEW" 2>&1 | grep -E 'Failed to start|migration.*(fail|error)|SQLITE_|\[security\]'; then fail "log lines above need review"; else ok "logs: no startup, migration or security errors"; fi

step "8. Smoke tests"
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@"; }
[ "$(code "$BASE_URL/api/ping")" = 200 ] && ok "HTTPS /api/ping 200" || fail "/api/ping"
[ "$(code "$BASE_URL/")" = 200 ] && ok "dashboard served" || fail "dashboard not served"
[ "$(code "$BASE_URL/v1/models")" = 401 ] && ok "/v1 requires a key" || fail "/v1 without a key is not 401"
curl -s "$BASE_URL/api/auth/status" | grep -q '"needsSetup":false' && ok "existing account preserved (needsSetup:false)" || fail "dashboard reports needsSetup: data not preserved?"
if [ -n "${ADMIN_EMAIL:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
  T="$(curl -s -X POST -H 'Content-Type: application/json' -d "$(python3 -c 'import json,os;print(json.dumps({"email":os.environ["ADMIN_EMAIL"],"password":os.environ["ADMIN_PASSWORD"]}))')" "$BASE_URL/api/auth/login" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("token",""))')"
  [ -n "$T" ] && ok "login with existing credentials" || fail "login failed"
  K="$(curl -s -H "Authorization: Bearer $T" "$BASE_URL/api/settings/api-key" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("apiKey",""))')"
  [ "$(code -H "Authorization: Bearer $K" "$BASE_URL/v1/models")" = 200 ] && ok "/v1 with the existing unified key -> 200" || fail "/v1 with the existing key"
  [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $T" "$BASE_URL/api/keys")" = 200 ] && ok "stored provider keys readable (encryption key intact)" || fail "/api/keys"
else
  echo "  (set ADMIN_EMAIL/ADMIN_PASSWORD to include login and API-key smoke tests)"
fi
echo
[ "$FAILURES" = 0 ] && echo "Production switched to $RELEASE_IMAGE. Rollback kit: $BK" || { echo "$FAILURES check(s) FAILED. Roll back with: rollback.sh $BK"; exit 1; }
