#!/usr/bin/env bash
# Verify the published release image for one commit, straight from GHCR.
#   ./verify-image.sh <full-40-char-commit-sha>
# Checks: the sha-<short> tag exists in ghcr.io/yuktastv/freellmapi; its index
# has linux/amd64 and linux/arm64; EACH platform's image config carries
# org.opencontainers.image.revision == the full SHA and
# org.opencontainers.image.source == https://github.com/yuktastv/freellmapi.
# Prints the index digest to pin (image@sha256:...). Exits non-zero on any
# mismatch. Anonymous pull only: the package is public.
set -euo pipefail
SHA="${1:?usage: verify-image.sh <full commit sha>}"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "FAIL: not a full 40-char SHA: $SHA" >&2; exit 2; }
REPO="yuktastv/freellmapi"
TAG="sha-${SHA:0:7}"
EXPECT_SOURCE="https://github.com/${REPO}"
TOKEN="$(curl -fsS "https://ghcr.io/token?scope=repository:${REPO}:pull" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')"
reg() { curl -fsS -H "Authorization: Bearer ${TOKEN}" "$@"; }
ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json'
INDEX="$(reg -H "Accept: ${ACCEPT}" "https://ghcr.io/v2/${REPO}/manifests/${TAG}")" \
  || { echo "FAIL: ${REPO}:${TAG} not found in GHCR" >&2; exit 1; }
DIGEST="$(reg -I -H "Accept: ${ACCEPT}" "https://ghcr.io/v2/${REPO}/manifests/${TAG}" | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')"
fail=0
for arch in amd64 arm64; do
  m="$(printf '%s' "$INDEX" | python3 -c "import json,sys;d=json.load(sys.stdin);print(next((x['digest'] for x in d['manifests'] if x.get('platform',{}).get('os')=='linux' and x['platform'].get('architecture')=='$arch'),''))")"
  if [ -z "$m" ]; then echo "FAIL: no linux/$arch manifest"; fail=1; continue; fi
  cfg="$(reg -H 'Accept: application/vnd.oci.image.manifest.v1+json' "https://ghcr.io/v2/${REPO}/manifests/${m}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["config"]["digest"])')"
  labels="$(reg -L "https://ghcr.io/v2/${REPO}/blobs/${cfg}" | python3 -c 'import json,sys;l=json.load(sys.stdin)["config"].get("Labels") or {};print(l.get("org.opencontainers.image.revision",""), l.get("org.opencontainers.image.source",""))')"
  rev="${labels%% *}"; src="${labels#* }"
  if [ "$rev" = "$SHA" ] && [ "$src" = "$EXPECT_SOURCE" ]; then
    echo "OK:   linux/$arch  manifest=$m  revision=$rev  source=$src"
  else
    echo "FAIL: linux/$arch  revision=$rev (want $SHA)  source=$src (want $EXPECT_SOURCE)"; fail=1
  fi
done
[ "$fail" = 0 ] || exit 1
echo "IMAGE=ghcr.io/${REPO}:${TAG}@${DIGEST}"
