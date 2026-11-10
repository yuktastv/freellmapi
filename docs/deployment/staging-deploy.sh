#!/usr/bin/env bash
# Deploy FreeLLMAPI to STAGING. Run on the staging host, from a checkout of
# https://github.com/yuktastv/freellmapi at the release commit.
#
#   RELEASE_SHA=<full sha> RELEASE_IMAGE='ghcr.io/yuktastv/freellmapi:sha-xxxxxxx@sha256:...' \
#     ./staging-deploy.sh /path/to/freellmapi-checkout
#
# RELEASE_IMAGE is the IMAGE= line printed by verify-image.sh (tag AND digest).
# - Separate Compose project (freellmapi-staging) and volume.
# - Fresh install: generates a NEW ENCRYPTION_KEY (never printed).
#   Existing staging install: keeps its key, and runs the migration check and a
#   verified backup before switching.
# - The app port stays on 127.0.0.1; nginx in front terminates TLS.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/lib.sh"
CHECKOUT="${1:?usage: staging-deploy.sh <fork checkout at release commit>}"
: "${RELEASE_SHA:?set RELEASE_SHA}"; : "${RELEASE_IMAGE:?set RELEASE_IMAGE (from verify-image.sh)}"
PROJECT=freellmapi-staging
VOLUME="${PROJECT}_freellmapi-data"
need docker git sha256sum tar curl openssl; need_compose
cd "$CHECKOUT"

step "Preflight"
[ "$(git rev-parse HEAD)" = "$RELEASE_SHA" ] || die "checkout is at $(git rev-parse --short HEAD), not the release ${RELEASE_SHA:0:7}"
git remote get-url origin | grep -q 'yuktastv/freellmapi' || die "checkout origin is not the fork: $(git remote get-url origin)"
case "$RELEASE_IMAGE" in ghcr.io/yuktastv/freellmapi:sha-"${RELEASE_SHA:0:7}"@sha256:*) ok "release image $RELEASE_IMAGE";; *) die "RELEASE_IMAGE must be ghcr.io/yuktastv/freellmapi:sha-${RELEASE_SHA:0:7}@sha256:...";; esac
[ -f deploy/staging/docker-compose.staging.yml ] || die "staging overlay missing in checkout"

step "Install state"
if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  echo "  existing staging volume $VOLUME"
  env_has ENCRYPTION_KEY || die "existing staging volume but no ENCRYPTION_KEY in .env: refusing (would make stored keys undecryptable)"
  CID="$(container_of "$PROJECT")"
  if [ -n "$CID" ]; then
    echo "  running: $(docker inspect --format '{{.Config.Image}} revision={{ index .Config.Labels "org.opencontainers.image.revision" }}' "$CID")"
    migration_check "$CID" "$CHECKOUT" || die "database has migrations this release does not know: refusing to downgrade"
    ok "migration check: compatible"
    BK="$HOME/freellmapi-backups/staging-$(date -u +%Y%m%dT%H%M%SZ)"
    backup_install "$CID" "$VOLUME" "$BK"; ok "backup verified: $BK"
  else
    die "staging volume exists but no running container to check migrations against; start the previous image first, or remove the staging volume deliberately"
  fi
else
  echo "  fresh staging install"
  if env_has ENCRYPTION_KEY; then
    echo "  .env already has an ENCRYPTION_KEY: keeping it (never replaced)"
  else
    ( umask 077; printf 'ENCRYPTION_KEY=%s\n' "$(openssl rand -hex 32)" >> .env ); ok "generated a new ENCRYPTION_KEY (not printed)"
  fi
fi
chmod 600 .env
KEY_BEFORE="$(key_hash)"

step "Configuration"
env_append FREELLMAPI_IMAGE_TAG "sha-${RELEASE_SHA:0:7}"   # required by the base file; the image below wins
env_append HOST_BIND 127.0.0.1
env_append PORT 3001
[ "$(env_get HOST_BIND)" = 127.0.0.1 ] || die "HOST_BIND in .env is '$(env_get HOST_BIND)': staging must publish on 127.0.0.1 only"
# Host-local, uncommitted: pins tag AND digest, so a re-pushed tag cannot change what runs.
cat > docker-compose.release.yml <<EOF
services:
  freellmapi:
    image: ${RELEASE_IMAGE}
EOF
COMPOSE=(docker compose -p "$PROJECT" -f docker-compose.yml -f deploy/staging/docker-compose.staging.yml -f docker-compose.release.yml)
cfg="$("${COMPOSE[@]}" config)"
grep -q "image: ${RELEASE_IMAGE}" <<<"$cfg" && ok "image pinned by digest" || die "rendered config does not use $RELEASE_IMAGE"
for kv in 'TRUST_PROXY: "1"' 'DISABLE_LOCAL_TRUST: "true"' "FREELLMAPI_UPDATE_CHECK: 'off'" 'FREELLMAPI_SELF_UPDATE_URL: ""' 'com.centurylinklabs.watchtower.enable: "false"' "name: ${VOLUME}"; do
  grep -qF "$kv" <<<"$cfg" && ok "$kv" || die "rendered config is missing: $kv"
done
grep -q 'host_ip: 127.0.0.1' <<<"$cfg" && ok "port published on 127.0.0.1 only" || die "port is not bound to 127.0.0.1"
grep -q 'build:' <<<"$cfg" && die "staging config still has a build section" || ok "no build fallback"

step "Deploy"
"${COMPOSE[@]}" pull freellmapi
"${COMPOSE[@]}" up -d freellmapi          # never the autoupdate profile
CID="$(container_of "$PROJECT")"; [ -n "$CID" ] || die "container did not start"
wait_healthy "$CID" && ok "healthy" || { docker logs --tail 50 "$CID"; die "container not healthy"; }
verify_running_image "$CID" "$RELEASE_IMAGE" "$RELEASE_SHA"
[ "$(key_hash)" = "$KEY_BEFORE" ] && ok "ENCRYPTION_KEY unchanged" || die "ENCRYPTION_KEY changed during deploy"
docker ps --format '{{.Names}}' | grep -q watchtower && fail "a watchtower container is running on this host" || ok "no watchtower running"
if docker logs "$CID" 2>&1 | grep -E 'Failed to start|migration.*(fail|error)|SQLITE_|\[security\]'; then fail "log lines above need review"; else ok "logs: no startup, migration or security errors"; fi
echo
echo "First-run setup code (only on a fresh install; read it privately):"
echo "  docker logs $CID 2>&1 | grep 'First-run setup code'"
[ "${FAILURES:-0}" = 0 ] || die "$FAILURES check(s) failed"
echo; echo "Staging deployed. Next: staging-external-checks.sh from ANOTHER machine, BEFORE creating the account."
