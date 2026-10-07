#!/usr/bin/env bash
# Checks that vCluster Platform is reachable through the Envoy Gateway edge,
# including the HTTP upgrades private nodes need.
#
#   PLATFORM_HOST=platform.example.com hack/check.sh
#
# Optional:
#   CORS_ORIGIN=https://status.apps.example.com   also check a CORS preflight
#   PLATFORM_NAMESPACE=vcluster-platform          where the routes live
#   SKIP_KUBECTL=1                                only run the HTTP probes
set -uo pipefail

host="${PLATFORM_HOST:?set PLATFORM_HOST to your vCluster Platform hostname}"
ns="${PLATFORM_NAMESPACE:-vcluster-platform}"
base="https://${host}"
failures=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }

echo "Gateway API objects"
if [[ -z "${SKIP_KUBECTL:-}" ]]; then
  for obj in httproute/vcluster-platform httproute/vcluster-platform-redirect; do
    status=$(kubectl -n "$ns" get "$obj" \
      -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
    [[ "$status" == "True" ]] && pass "$obj accepted" || fail "$obj accepted (got '${status:-missing}')"
  done
  for obj in backendtrafficpolicy/vcluster-platform-upgrades; do
    status=$(kubectl -n "$ns" get "$obj" \
      -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
    [[ "$status" == "True" ]] && pass "$obj accepted" || fail "$obj accepted (got '${status:-missing}')"
  done
else
  echo "  skipped (SKIP_KUBECTL set)"
fi

echo "HTTP"
c=$(code "${base}/version");                    [[ "$c" == 200 ]] && pass "GET /version -> 200" || fail "GET /version -> $c, want 200"
c=$(code "http://${host}/version");             [[ "$c" == 301 ]] && pass "port 80 redirects -> 301" || fail "port 80 -> $c, want 301"

echo "Upgrades"
# A handshake-less probe can't complete the Tailscale upgrade, so vCluster
# Platform answers 400. A 403 with an empty body is Envoy refusing the upgrade
# type before the request reaches vCluster Platform.
body=$(curl -s --http1.1 -X POST --max-time 10 \
  -H 'Upgrade: tailscale-control-protocol' -H 'Connection: upgrade' "${base}/ts2021")
[[ "$body" == *"missing Tailscale handshake header"* ]] \
  && pass "tailscale-control-protocol reaches vCluster Platform" \
  || fail "tailscale-control-protocol blocked (got '${body:-empty body, likely 403 upgrade_failed}')"

c=$(code --http1.1 --max-time 3 -H 'Upgrade: DERP' -H 'Connection: Upgrade' "${base}/derp")
[[ "$c" == 101 ]] && pass "DERP upgrade -> 101" || fail "DERP upgrade -> $c, want 101"

c=$(code --http1.1 --max-time 3 -H 'Upgrade: websocket' -H 'Connection: Upgrade' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  -H 'Sec-WebSocket-Protocol: derp' "${base}/derp")
[[ "$c" == 101 ]] && pass "websocket upgrade -> 101" || fail "websocket upgrade -> $c, want 101"

if [[ -n "${CORS_ORIGIN:-}" ]]; then
  echo "CORS"
  allow=$(curl -s -D - -o /dev/null --max-time 10 -X OPTIONS \
    -H "Origin: ${CORS_ORIGIN}" -H 'Access-Control-Request-Method: GET' \
    -H 'Access-Control-Request-Headers: authorization' "${base}/version" \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="access-control-allow-origin"{print $2}')
  [[ "$allow" == "$CORS_ORIGIN" ]] && pass "preflight from ${CORS_ORIGIN} allowed" \
    || fail "preflight from ${CORS_ORIGIN}: Access-Control-Allow-Origin '${allow:-missing}'"
  other=$(curl -s -D - -o /dev/null --max-time 10 -X OPTIONS \
    -H 'Origin: https://not-allowed.invalid' -H 'Access-Control-Request-Method: GET' "${base}/version" \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="access-control-allow-origin"{print $2}')
  [[ -z "$other" ]] && pass "preflight from another origin not allowed" \
    || fail "preflight from another origin was allowed ('${other}')"
fi

echo
if (( failures > 0 )); then
  echo "${failures} check(s) failed"
  exit 1
fi
echo "all checks passed"
