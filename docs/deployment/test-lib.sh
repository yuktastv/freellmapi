#!/usr/bin/env bash
# Tests for the safety logic in lib.sh that the deploy and rollback scripts rely
# on. Needs no Docker daemon: `docker` is replaced by a stub that serves a real,
# freshly migrated SQLite database and archives a real directory.
#
#   (from the repo root, after npm ci)  docs/deployment/test-lib.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
set +e
FAILURES=0
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/vol" "$T/work"

FREEAPI_DB_PATH="$T/vol/freeapi.db" NODE_ENV=development \
  npx --prefix "$ROOT" tsx "$ROOT/server/src/db/migrate/cli.ts" up >/dev/null 2>&1 \
  || { echo "could not create a test database (run npm ci first)"; exit 1; }

EXEC_FAIL=0
docker() {
  case "$1" in
    exec) [ "$EXEC_FAIL" = 1 ] && return 1
          FREEAPI_DB_PATH="$T/vol/freeapi.db" NODE_PATH="$ROOT/node_modules" node -e "${*: -1}" ;;
    stop) : ;;
    run)  tar czf "$BKDIR/data.tgz" -C "$T/vol" . ;;
    *)    echo "unexpected: docker $*" >&2; return 1 ;;
  esac
}
add_migration() { NODE_PATH="$ROOT/node_modules" node -e "const D=require('better-sqlite3');new D('$T/vol/freeapi.db').prepare(\"INSERT INTO migrations (filename) VALUES ('$1')\").run()"; }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1 (got $2, want $3)"; }
cd "$T/work"

step "env helpers never replace ENCRYPTION_KEY"
printf 'ENCRYPTION_KEY=%s\n' "$(openssl rand -hex 32)" > .env; before="$(key_hash)"
env_append ENCRYPTION_KEY must-not-be-written
env_append FREELLMAPI_IMAGE_TAG sha-aaaaaaa; env_append FREELLMAPI_IMAGE_TAG sha-bbbbbbb
expect "key unchanged" "$(key_hash)" "$before"
expect "one key line" "$(grep -c ENCRYPTION_KEY .env)" 1
expect "append-only keeps the first value" "$(env_get FREELLMAPI_IMAGE_TAG)" sha-aaaaaaa

step "migration_check"
migration_check cid "$ROOT" >/dev/null; expect "same release is compatible" "$?" 0
EXEC_FAIL=1; migration_check cid "$ROOT" >/dev/null; expect "a failed query is refused (fails closed)" "$?" 2; EXEC_FAIL=0
add_migration 20991231_000001_newer_upstream.ts
migration_check cid "$ROOT" >/dev/null; expect "a database with an unknown migration is refused" "$?" 1

step "backup_install"
BKDIR="$T/bk"; ( backup_install cid vol "$BKDIR" ); expect "backup succeeds" "$?" 0
expect "backup dir mode" "$(stat -c %a "$BKDIR")" 700
expect "archive mode" "$(stat -c %a "$BKDIR/data.tgz")" 600
expect ".env copy mode" "$(stat -c %a "$BKDIR/env.backup")" 600
cmp -s .env "$BKDIR/env.backup"; expect ".env copied byte for byte" "$?" 0
(cd "$BKDIR" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1); expect "checksums verify" "$?" 0
echo x >> "$BKDIR/data.tgz"
(cd "$BKDIR" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1); expect "tampering is detected" "$?" 1

echo
[ "$FAILURES" = 0 ] && echo "lib.sh: all tests passed" || { echo "lib.sh: $FAILURES test(s) FAILED"; exit 1; }
