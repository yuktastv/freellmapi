#!/usr/bin/env bash
# Shared helpers for the FreeLLMAPI release scripts. Sourced, not run.
# Nothing here prints a secret: ENCRYPTION_KEY, passwords and API keys are only
# ever tested for presence or compared by hash.
set -euo pipefail

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILURES=$((${FAILURES:-0}+1)); }
die()  { printf '\033[31mABORT:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

need() { for c in "$@"; do command -v "$c" >/dev/null || die "missing command: $c"; done; }

# docker compose >= 2.24 (the staging overlay uses !reset)
need_compose() {
  local v; v="$(docker compose version --short 2>/dev/null | sed 's/^v//')" || die "docker compose v2 not available"
  local major minor; major="${v%%.*}"; minor="$(echo "$v" | cut -d. -f2)"
  { [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 24 ]; }; } || die "docker compose $v is too old (need >= 2.24)"
}

# .env helpers. Lines are only ever APPENDED when missing, never rewritten,
# so an existing ENCRYPTION_KEY can never be replaced by these scripts.
env_has()    { grep -qE "^${1}=" .env 2>/dev/null; }
env_get()    { grep -E "^${1}=" .env | tail -1 | cut -d= -f2-; }   # never call for secrets
env_append() { env_has "$1" || printf '%s=%s\n' "$1" "$2" >> .env; }
key_hash()   { grep -E '^ENCRYPTION_KEY=' .env | sha256sum | cut -d' ' -f1; }

# Running freellmapi container of a compose project (empty if none).
container_of() { docker ps -q --filter "label=com.docker.compose.project=$1" --filter label=com.docker.compose.service=freellmapi | head -1; }

wait_healthy() {
  local cid="$1" s _
  for _ in $(seq 1 60); do
    s="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo gone)"
    [ "$s" = healthy ] && return 0
    [ "$s" = gone ] || [ "$s" = exited ] && return 1
    sleep 2
  done
  return 1
}

# Assert a running container runs exactly IMAGE (repo@sha256:index-digest)
# with the expected OCI revision label.
verify_running_image() {
  local cid="$1" image="$2" sha="$3" id repodigests rev
  id="$(docker inspect --format '{{.Image}}' "$cid")"
  repodigests="$(docker image inspect --format '{{join .RepoDigests " "}}' "$id")"
  rev="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$id")"
  local expected="ghcr.io/yuktastv/freellmapi@${image##*@}"
  case " $repodigests " in
    *" $expected "*) ok "container runs $expected";;
    *) fail "container image digests [$repodigests] do not include $expected";;
  esac
  [ "$rev" = "$sha" ] && ok "OCI revision $rev" || fail "OCI revision '$rev' != $sha"
  case "$repodigests" in *tashfeenahmed*) fail "image comes from the UPSTREAM repository";; esac
}

# Read-only migration compatibility check: migrations applied in the database
# that this release does not ship. Prints them; returns 1 if any.
migration_check() {
  # Fails CLOSED: any error reading the database, or a database that reports
  # no applied migrations at all, is a refusal (return 2), never "compatible".
  local cid="$1" release_checkout="$2" out
  out="$(mktemp -d)"
  if ! docker exec "$cid" node -e "const D=require('better-sqlite3');const d=new D(process.env.FREEAPI_DB_PATH||'/app/server/data/freeapi.db',{readonly:true});for(const r of d.prepare('SELECT filename FROM migrations ORDER BY filename').all())console.log(r.filename)" > "$out/applied.raw"; then
    echo "  could not read the database's migrations table"; return 2
  fi
  sort "$out/applied.raw" > "$out/applied"
  [ -s "$out/applied" ] || { echo "  database reports no applied migrations: cannot judge compatibility"; return 2; }
  find "$release_checkout/server/src/db/migrations" -maxdepth 1 -name '*.ts' -exec basename {} \; | sort > "$out/release"
  [ -s "$out/release" ] || { echo "  no migrations found in the release checkout"; return 2; }
  local unknown; unknown="$(comm -23 "$out/applied" "$out/release")"
  echo "  applied=$(wc -l < "$out/applied") release=$(wc -l < "$out/release") pending-for-release=$(comm -13 "$out/applied" "$out/release" | wc -l)"
  if [ -n "$unknown" ]; then echo "$unknown" | sed 's/^/  UNKNOWN MIGRATION: /'; return 1; fi
  return 0
}

# Consistent backup: stop the container, archive the data volume, copy .env;
# write SHA-256 checksums and verify both archive integrity and checksums.
# Leaves the container STOPPED. Prints the backup directory.
backup_install() {
  local cid="$1" volume="$2" dest="$3"
  mkdir -p "$dest"; chmod 700 "$dest"
  docker stop "$cid" >/dev/null
  docker run --rm -v "$volume":/data:ro -v "$dest":/backup alpine \
    tar czf /backup/data.tgz -C /data .
  cp -p .env "$dest/env.backup"; chmod 600 "$dest/env.backup" "$dest/data.tgz"
  (cd "$dest" && sha256sum data.tgz env.backup > SHA256SUMS && sha256sum -c --quiet SHA256SUMS) || die "backup checksum verification failed"
  # List to a file first: `tar | grep -q` fails under pipefail when grep exits early.
  tar tzf "$dest/data.tgz" > "$dest/.listing" || die "backup archive is not readable"
  grep -qE '\.db$' "$dest/.listing" || die "backup archive contains no SQLite database file"
  rm -f "$dest/.listing"
}
