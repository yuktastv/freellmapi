#!/usr/bin/env bash
# Roll production back to the PREVIOUS image AND the database backup taken
# immediately before the switch. An image rollback alone does not undo
# migrations, so this always restores both together.
#
#   CONFIRM=yes ./rollback.sh <backup dir printed by prod-deploy.sh> <install dir>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/lib.sh"
BK="${1:?usage: rollback.sh <backup dir> <install dir>}"; DIR="${2:?usage: rollback.sh <backup dir> <install dir>}"
[ "${CONFIRM:-}" = yes ] || die "this REPLACES the data volume with the backup. Re-run with CONFIRM=yes"
need docker sha256sum tar; need_compose
# shellcheck disable=SC1091
source "$BK/rollback.env"
[ -n "${PREV_DIGEST:-}" ] && [ -n "${VOLUME:-}" ] && [ -n "${PROD_PROJECT:-}" ] || die "rollback.env is incomplete"

step "Verify the backup"
(cd "$BK" && sha256sum -c --quiet SHA256SUMS) || die "backup checksums do not match"
tar tzf "$BK/data.tgz" >/dev/null || die "backup archive unreadable"
ok "backup intact"

step "Stop the release container (the volume is kept)"
CID="$(container_of "$PROD_PROJECT")"; [ -z "$CID" ] || docker rm -f "$CID" >/dev/null
ok "stopped"

step "Restore the data volume and .env"
docker run --rm -v "$VOLUME":/data -v "$BK":/backup:ro alpine sh -c 'find /data -mindepth 1 -delete && tar xzf /backup/data.tgz -C /data'
cd "$DIR"; cp -p "$BK/env.backup" .env; chmod 600 .env
ok "volume and .env restored from $BK"

step "Start the previous image by digest"
cat > docker-compose.rollback.yml <<EOF
services:
  freellmapi:
    image: ${PREV_DIGEST}
    build: !reset null
EOF
rm -f docker-compose.release.yml
# The previous .env may predate FREELLMAPI_IMAGE_TAG; the base file needs it set
# to interpolate, and the rollback override decides the image.
FREELLMAPI_IMAGE_TAG="${FREELLMAPI_IMAGE_TAG:-rollback}" docker compose -p "$PROD_PROJECT" -f docker-compose.yml -f docker-compose.rollback.yml up -d freellmapi
NEW="$(container_of "$PROD_PROJECT")"
wait_healthy "$NEW" && ok "previous image healthy" || die "previous image did not become healthy"
echo "  running: $(docker inspect --format '{{.Config.Image}}' "$NEW")  revision=$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$(docker inspect --format '{{.Image}}' "$NEW")")  (expected revision ${PREV_REVISION:-<none>})"
