#!/usr/bin/env bash
# Outside-in staging checks. Run from a machine that is NOT the staging host,
# right after staging-deploy.sh and BEFORE the first account is created
# (test 4 relies on setup still being open).
#
#   BASE_URL=https://staging.example.com STAGING_IP=203.0.113.10 ./staging-external-checks.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/lib.sh"; set +e
: "${BASE_URL:?set BASE_URL (https://...)}"; : "${STAGING_IP:?set STAGING_IP (public address of the host)}"
FAILURES=0
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@"; }

step "9. TLS and forwarding headers"
c="$(code "$BASE_URL/api/ping")"; [ "$c" = 200 ] && ok "HTTPS with a valid certificate: /api/ping 200" || fail "HTTPS /api/ping returned $c (certificate or proxy problem)"
hdrs="$(curl -sS -D - -o /dev/null --max-time 15 "$BASE_URL/")"
grep -qi '^content-security-policy:.*upgrade-insecure-requests' <<<"$hdrs" && ok "X-Forwarded-Proto https reached the app (CSP upgrade-insecure-requests)" || fail "CSP lacks upgrade-insecure-requests: X-Forwarded-Proto not forwarded or not trusted"
grep -qi '^cross-origin-opener-policy: same-origin' <<<"$hdrs" && ok "secure-context headers present" || fail "Cross-Origin-Opener-Policy missing over HTTPS"
c="$(code "http://${BASE_URL#https://}/api/ping")"; case "$c" in 301|308) ok "plain HTTP redirects to HTTPS ($c)";; 000) ok "plain HTTP not served";; *) fail "plain HTTP answered $c (expected a redirect or no listener)";; esac

step "5. Application port is not public"
c="$(code --connect-timeout 5 "http://${STAGING_IP}:3001/api/ping")"
[ "$c" = 000 ] && ok "port 3001 unreachable from outside" || fail "port 3001 answered $c from outside"

step "4. Spoofed local-trust requests"
st="$(curl -s --max-time 15 "$BASE_URL/api/auth/status")"
grep -q '"needsSetup":true' <<<"$st" || { fail "setup is already complete: run this before creating the account (test not meaningful)"; }
for h in "X-Forwarded-For: 127.0.0.1" "X-Real-IP: 127.0.0.1" "X-Forwarded-For: 127.0.0.1, 127.0.0.1"; do
  c="$(code -X POST -H 'Host: localhost' -H "$h" -H 'Content-Type: application/json' -d '{"email":"x"}' "$BASE_URL/api/auth/setup")"
  [ "$c" = 403 ] && ok "setup with '$h' + Host: localhost -> 403" || fail "setup with '$h' -> $c (400 means treated as local!)"
done
c="$(code -X POST -H 'Host: localhost' -H 'X-Forwarded-For: 127.0.0.1' "$BASE_URL/api/auth/desktop-session")"
[ "$c" = 403 ] && ok "desktop-session spoof -> 403" || fail "desktop-session spoof -> $c"
grep -q '"desktop":false' <<<"$st" && ok "status reports desktop:false" || fail "status does not report desktop:false"

echo; [ "$FAILURES" = 0 ] && echo "External checks passed. Now create the first account with the setup code, then run staging-host-tests.sh on the host." || { echo "$FAILURES external check(s) FAILED"; exit 1; }
