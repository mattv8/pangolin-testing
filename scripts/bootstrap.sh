#!/usr/bin/env bash
# Bootstrap script for Pangolin DNS Authority test stack.
# Creates the admin, org, domain, Newt sites, resources, and targets needed by
# the local DNS Authority and Auth Proxy end-to-end tests.

set -euo pipefail

BASE="http://localhost:3001/api/v1"
COOKIES="/tmp/pangolin-cookies.txt"
ORG_ID="test-org"
DOMAIN="test.dev"
ADMIN_EMAIL="admin@test.dev"
ADMIN_PASSWORD="TestAdmin123!"
NEWT_SECRET="test-secret-for-local-development-only"

echo "=== Pangolin DNS Authority Test Bootstrap ==="
echo ""

json_get() {
    local path="$1"
    python3 -c '
import json, sys
path = sys.argv[1].split(".") if sys.argv[1] else []
value = json.load(sys.stdin)
for part in path:
    if isinstance(value, list):
        value = value[int(part)]
    else:
        value = value.get(part)
    if value is None:
        print("")
        sys.exit(0)
if isinstance(value, bool):
    print("True" if value else "False")
else:
    print(value)
' "$path"
}

json_find() {
    local collection_path="$1"
    local key="$2"
    local value="$3"
    local return_key="$4"
    python3 -c '
import json, sys
collection_path, key, expected, return_key = sys.argv[1:]
data = json.load(sys.stdin)
items = data
for part in collection_path.split("."):
    items = items.get(part, {}) if isinstance(items, dict) else {}
for item in items if isinstance(items, list) else []:
    if str(item.get(key, "")) == expected:
        print(item.get(return_key, ""))
        sys.exit(0)
print("")
' "$collection_path" "$key" "$value" "$return_key"
}

api() {
    local method="$1"
    local path="$2"
    local data="${3:-}"
    local tmp code body success
    tmp=$(mktemp)

    if [ -n "$data" ]; then
        code=$(curl -sS -w '%{http_code}' -o "$tmp" -X "$method" \
            -b "$COOKIES" -c "$COOKIES" \
            -H "Content-Type: application/json" \
            -d "$data" \
            "$BASE$path")
    else
        code=$(curl -sS -w '%{http_code}' -o "$tmp" -X "$method" \
            -b "$COOKIES" -c "$COOKIES" \
            "$BASE$path")
    fi

    body=$(cat "$tmp")
    rm -f "$tmp"

    if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
        echo "ERROR: $method $path returned HTTP $code" >&2
        echo "$body" >&2
        exit 1
    fi

    if [ -n "$body" ]; then
        success=$(printf '%s' "$body" | json_get success 2>/dev/null || echo "")
        if [ "$success" = "False" ]; then
            echo "ERROR: $method $path returned an API error" >&2
            echo "$body" >&2
            exit 1
        fi
    fi

    printf '%s' "$body"
}

login() {
    local tmp code body
    tmp=$(mktemp)
    code=$(curl -sS -w '%{http_code}' -o "$tmp" -X POST "$BASE/auth/login" \
        -H "Content-Type: application/json" \
        -c "$COOKIES" \
        -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")
    body=$(cat "$tmp")
    rm -f "$tmp"

    if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
        echo "ERROR: login returned HTTP $code" >&2
        echo "$body" >&2
        exit 1
    fi
}

find_site_id_by_name() {
    api GET "/org/$ORG_ID/sites" | json_find data.sites name "$1" siteId
}

find_domain_id() {
    api GET "/org/$ORG_ID/domains" | json_find data.domains baseDomain "$DOMAIN" domainId
}

find_resource_id_by_domain() {
    api GET "/org/$ORG_ID/resources" | json_find data.resources fullDomain "$1" resourceId
}

target_exists() {
    local resource_id="$1"
    local site_id="$2"
    local ip="$3"
    local port="$4"
    api GET "/resource/$resource_id/targets" | python3 -c '
import json, sys
site_id, ip, port = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(sys.stdin)
for target in data.get("data", {}).get("targets", []):
    if str(target.get("siteId")) == site_id and target.get("ip") == ip and str(target.get("port")) == port:
        print("yes")
        sys.exit(0)
print("no")
' "$site_id" "$ip" "$port"
}

ensure_site() {
    local name="$1"
    local newt_id="$2"
    local public_ip="$3"
    local site_id site_json existing_newt_id response payload

    site_id=$(find_site_id_by_name "$name")
    if [ -n "$site_id" ]; then
        site_json=$(api GET "/site/$site_id")
        existing_newt_id=$(printf '%s' "$site_json" | json_get data.newtId)
        if [ "$existing_newt_id" != "$newt_id" ]; then
            echo "ERROR: Site '$name' has Newt ID '$existing_newt_id', expected '$newt_id'" >&2
            exit 1
        fi
        echo "    Site '$name' already exists with ID $site_id."
    else
        payload=$(printf '{"name":"%s","type":"newt","newtId":"%s","secret":"%s"}' "$name" "$newt_id" "$NEWT_SECRET")
        response=$(api PUT "/org/$ORG_ID/site" "$payload")
        site_id=$(printf '%s' "$response" | json_get data.siteId)
        echo "    Site created: $name (siteId=$site_id, newtId=$newt_id)"
    fi

    api POST "/site/$site_id" "{\"dnsAuthorityEnabled\":true,\"publicIp\":\"$public_ip\"}" >/dev/null
    echo "    DNS Authority enabled on siteId $site_id, publicIp: $public_ip"
    printf '%s\n' "$site_id"
}

ensure_resource() {
    local name="$1"
    local subdomain="$2"
    local update_json="$3"
    local domain_id="$4"
    local full_domain resource_id response payload

    full_domain="$subdomain.$DOMAIN"
    resource_id=$(find_resource_id_by_domain "$full_domain")
    if [ -n "$resource_id" ]; then
        echo "    Resource '$full_domain' already exists with ID $resource_id."
    else
        payload=$(printf '{"name":"%s","http":true,"protocol":"tcp","domainId":"%s","subdomain":"%s"}' "$name" "$domain_id" "$subdomain")
        response=$(api PUT "/org/$ORG_ID/resource" "$payload")
        resource_id=$(printf '%s' "$response" | json_get data.resourceId)
        echo "    Resource created: $full_domain (resourceId=$resource_id)"
    fi

    api POST "/resource/$resource_id" "$update_json" >/dev/null
    printf '%s\n' "$resource_id"
}

ensure_target() {
    local resource_id="$1"
    local site_id="$2"
    local ip="$3"
    local port="$4"
    local extra_fields="${5:-}"
    local payload

    if [ "$(target_exists "$resource_id" "$site_id" "$ip" "$port")" = "yes" ]; then
        echo "    Target already exists: resourceId=$resource_id siteId=$site_id $ip:$port"
        return
    fi

    payload=$(printf '{"siteId":%s,"ip":"%s","port":%s,"method":"http","enabled":true%s}' "$site_id" "$ip" "$port" "$extra_fields")
    api PUT "/resource/$resource_id/target" "$payload" >/dev/null
    echo "    Target added: resourceId=$resource_id siteId=$site_id $ip:$port"
}

wait_for_dns_listener() {
    local dns_server="$1"
    local name="$2"

    for _ in $(seq 1 45); do
        if docker compose exec -T test-client dig @"$dns_server" app.test.dev A +short +time=1 +tries=1 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            echo "    $name DNS is ready"
            return 0
        fi
        sleep 1
    done

    echo "ERROR: $name DNS did not answer within timeout" >&2
    return 1
}

echo "[1/8] Waiting for Pangolin API..."
for _ in $(seq 1 60); do
    if curl -s "$BASE/auth/initial-setup-complete" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

SETUP_COMPLETE=$(curl -s "$BASE/auth/initial-setup-complete" | json_get data.complete 2>/dev/null || echo "error")
if [ "$SETUP_COMPLETE" = "True" ]; then
    echo "    Setup already complete. Logging in..."
    login
    echo "    Logged in."
else
    echo "[2/8] Getting setup token from Pangolin logs..."
    SETUP_TOKEN=$(docker logs test-pangolin 2>&1 | grep "^Token:" | tail -1 | awk '{print $2}')
    if [ -z "$SETUP_TOKEN" ]; then
        echo "ERROR: Could not find setup token in Pangolin logs" >&2
        echo "Check: docker logs test-pangolin 2>&1 | grep Token" >&2
        exit 1
    fi
    echo "    Token: $SETUP_TOKEN"

    echo "[3/8] Creating server admin..."
    tmp=$(mktemp)
    code=$(curl -sS -w '%{http_code}' -o "$tmp" -X PUT "$BASE/auth/set-server-admin" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\",\"setupToken\":\"$SETUP_TOKEN\"}")
    body=$(cat "$tmp")
    rm -f "$tmp"
    if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
        echo "ERROR: set-server-admin returned HTTP $code" >&2
        echo "$body" >&2
        exit 1
    fi
    echo "    Admin created: $ADMIN_EMAIL"

    echo "[4/8] Logging in..."
    login
    echo "    Logged in."
fi

echo "[5/8] Creating organization..."
ORG_EXISTS=$(curl -s -b "$COOKIES" "$BASE/org/$ORG_ID" | json_get success 2>/dev/null || echo "False")
if [ "$ORG_EXISTS" = "True" ]; then
    echo "    Org '$ORG_ID' already exists, skipping."
else
    DEFAULTS=$(api GET "/pick-org-defaults")
    SUBNET=$(printf '%s' "$DEFAULTS" | json_get data.subnet)
    UTIL_SUBNET=$(printf '%s' "$DEFAULTS" | json_get data.utilitySubnet)
    api PUT "/org" "{\"orgId\":\"$ORG_ID\",\"name\":\"Test Organization\",\"subnet\":\"$SUBNET\",\"utilitySubnet\":\"$UTIL_SUBNET\"}" >/dev/null
    echo "    Org created: $ORG_ID"
fi

echo "[6/8] Ensuring domain and Newt sites..."
DOMAIN_ID=$(find_domain_id)
if [ -z "$DOMAIN_ID" ]; then
    DOMAIN_RESPONSE=$(api PUT "/org/$ORG_ID/domain" "{\"type\":\"wildcard\",\"baseDomain\":\"$DOMAIN\"}")
    DOMAIN_ID=$(printf '%s' "$DOMAIN_RESPONSE" | json_get data.domainId)
    echo "    Domain created: $DOMAIN (domainId=$DOMAIN_ID)"
else
    echo "    Domain '$DOMAIN' already exists with ID $DOMAIN_ID."
fi

SITE1_ID=$(ensure_site "Test Site" "test-newt-001" "172.28.0.10" | tail -n1)
SITE2_ID=$(ensure_site "Test Site Secondary" "test-newt-002" "172.28.0.11" | tail -n1)

echo "[7/8] Creating DNS Authority resources and targets..."
RESOURCE1_ID=$(ensure_resource "App" "app" '{"dnsAuthorityEnabled":true,"dnsAuthorityTtl":60,"dnsAuthorityRoutingPolicy":"roundrobin"}' "$DOMAIN_ID" | tail -n1)
ensure_target "$RESOURCE1_ID" "$SITE1_ID" "172.28.0.20" 80
ensure_target "$RESOURCE1_ID" "$SITE2_ID" "172.28.0.21" 80

echo ""
echo "[8/8] Waiting for Newt to connect and receive DNS zones..."
sleep 8
echo "    Waiting for DNS Authority listeners (Newt 1:172.28.0.10, Newt 2:172.28.0.11)..."
wait_for_dns_listener 172.28.0.10 "Newt 1"
wait_for_dns_listener 172.28.0.11 "Newt 2"

echo ""
echo "=== Creating Auth Proxy Test Resources ==="

echo "[AP-1] Creating multi.test.dev (multi-target + stickySession, no SSO)..."
RESOURCE2_ID=$(ensure_resource "Multi Target" "multi" '{"dnsAuthorityEnabled":true,"dnsAuthorityTtl":60,"dnsAuthorityRoutingPolicy":"roundrobin","stickySession":true,"sso":false}' "$DOMAIN_ID" | tail -n1)
ensure_target "$RESOURCE2_ID" "$SITE1_ID" "172.28.0.20" 80 ',"priority":50'
ensure_target "$RESOURCE2_ID" "$SITE1_ID" "172.28.0.21" 80 ',"priority":100'

echo "[AP-2] Creating pathtest.test.dev (path routing + strip prefix)..."
RESOURCE3_ID=$(ensure_resource "Path Test" "pathtest" '{"dnsAuthorityEnabled":true,"dnsAuthorityTtl":60,"dnsAuthorityRoutingPolicy":"roundrobin","sso":false}' "$DOMAIN_ID" | tail -n1)
ensure_target "$RESOURCE3_ID" "$SITE1_ID" "172.28.0.20" 80 ',"path":"/api","pathMatchType":"prefix","rewritePath":null,"rewritePathType":"stripPrefix","priority":10'
ensure_target "$RESOURCE3_ID" "$SITE1_ID" "172.28.0.21" 80 ',"priority":100'

echo "[AP-3] Creating headers.test.dev (custom headers + setHostHeader)..."
RESOURCE4_ID=$(ensure_resource "Headers Test" "headers" '{"dnsAuthorityEnabled":true,"dnsAuthorityTtl":60,"dnsAuthorityRoutingPolicy":"roundrobin","sso":true,"setHostHeader":"backend.internal","headers":[{"name":"X-Custom-Test","value":"hello-from-pangolin"},{"name":"X-Environment","value":"testing"}],"postAuthPath":"/dashboard"}' "$DOMAIN_ID" | tail -n1)
ensure_target "$RESOURCE4_ID" "$SITE1_ID" "172.28.0.20" 80

echo "[AP-4] Creating intelligent.test.dev (intelligent routing + health checks)..."
RESOURCE5_ID=$(ensure_resource "Intelligent DNS" "intelligent" '{"dnsAuthorityEnabled":true,"dnsAuthorityTtl":60,"dnsAuthorityRoutingPolicy":"roundrobin","stickySession":true,"sso":false}' "$DOMAIN_ID" | tail -n1)
ensure_target "$RESOURCE5_ID" "$SITE1_ID" "172.28.0.20" 80 ',"priority":50,"hcEnabled":true,"hcScheme":"http","hcHostname":"172.28.0.20","hcPort":80,"hcPath":"/","hcMethod":"GET","hcInterval":5,"hcUnhealthyInterval":5,"hcTimeout":2'
ensure_target "$RESOURCE5_ID" "$SITE2_ID" "172.28.0.21" 80 ',"priority":100,"hcEnabled":true,"hcScheme":"http","hcHostname":"172.28.0.21","hcPort":80,"hcPath":"/","hcMethod":"GET","hcInterval":5,"hcUnhealthyInterval":5,"hcTimeout":2'
api POST "/resource/$RESOURCE5_ID" '{"dnsAuthorityEnabled":true,"dnsAuthorityTtl":60,"dnsAuthorityRoutingPolicy":"intelligent","stickySession":true,"sso":false}' >/dev/null

echo "[AP-5] Creating stickycross.test.dev (cross-site sticky DNS affinity)..."
RESOURCE6_ID=$(ensure_resource "Sticky Cross Site" "stickycross" '{"dnsAuthorityEnabled":true,"dnsAuthorityTtl":60,"dnsAuthorityRoutingPolicy":"roundrobin","stickySession":true,"sso":false}' "$DOMAIN_ID" | tail -n1)
ensure_target "$RESOURCE6_ID" "$SITE1_ID" "172.28.0.20" 80 ',"priority":50'
ensure_target "$RESOURCE6_ID" "$SITE2_ID" "172.28.0.21" 80 ',"priority":100'

echo ""
echo "Waiting for auth proxy configs to propagate..."
sleep 5

echo ""
echo "=== DNS Authority Verification ==="
echo ""

RESULT_APP=$(docker compose exec -T test-client dig @172.28.0.10 app.test.dev A +short 2>/dev/null || echo "FAILED")
RESULT_APP2=$(docker compose exec -T test-client dig @172.28.0.11 app.test.dev A +short 2>/dev/null || echo "FAILED")
RESULT_WILD=$(docker compose exec -T test-client dig @172.28.0.10 random.test.dev A +short 2>/dev/null || echo "FAILED")
RESULT_MULTI=$(docker compose exec -T test-client dig @172.28.0.10 multi.test.dev A +short 2>/dev/null || echo "FAILED")
RESULT_PATH=$(docker compose exec -T test-client dig @172.28.0.10 pathtest.test.dev A +short 2>/dev/null || echo "FAILED")
RESULT_HDRS=$(docker compose exec -T test-client dig @172.28.0.10 headers.test.dev A +short 2>/dev/null || echo "FAILED")
RESULT_INTEL=$(docker compose exec -T test-client dig @172.28.0.10 intelligent.test.dev A +short 2>/dev/null || echo "FAILED")
RESULT_STICKYCROSS=$(docker compose exec -T test-client dig @172.28.0.10 stickycross.test.dev A +short 2>/dev/null || echo "FAILED")

echo "  app.test.dev (Newt 1)      -> ${RESULT_APP:-EMPTY}"
echo "  app.test.dev (Newt 2)      -> ${RESULT_APP2:-EMPTY}"
echo "  random.test.dev            -> ${RESULT_WILD:-EMPTY}"
echo "  multi.test.dev (Newt 1)    -> ${RESULT_MULTI:-EMPTY}"
echo "  pathtest.test.dev (Newt 1) -> ${RESULT_PATH:-EMPTY}"
echo "  headers.test.dev (Newt 1)  -> ${RESULT_HDRS:-EMPTY}"
echo "  intelligent.test.dev       -> ${RESULT_INTEL:-EMPTY}"
echo "  stickycross.test.dev       -> ${RESULT_STICKYCROSS:-EMPTY}"
echo ""

if [ "${RUN_BOOTSTRAP_SMOKE_TESTS:-0}" != "1" ]; then
    echo "Bootstrap complete. Set RUN_BOOTSTRAP_SMOKE_TESTS=1 to run optional Auth Proxy smoke checks."
    exit 0
fi

set +e

echo "=== Auth Proxy Integration Tests ==="
echo ""
PASS=0
FAIL=0

test_result() {
    local label="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (expected: $expected, got: $actual)"
        FAIL=$((FAIL + 1))
    fi
}

echo "[T1] app.test.dev - SSO redirect on HTTPS"
T1_CODE=$(docker exec test-client curl -sk -o /dev/null -w '%{http_code}' https://app.test.dev --resolve app.test.dev:443:172.28.0.10 2>/dev/null)
test_result "HTTPS SSO redirect returns 302" "$T1_CODE" "302"

echo "[T2] app.test.dev - HTTP to HTTPS redirect"
T2_CODE=$(docker exec test-client curl -s -o /dev/null -w '%{http_code}' http://app.test.dev --resolve app.test.dev:80:172.28.0.10 2>/dev/null)
test_result "HTTP to HTTPS redirect returns 301" "$T2_CODE" "301"

echo "[T3] multi.test.dev - direct proxy (no SSO)"
T3_CODE=$(docker exec test-client curl -sk -o /dev/null -w '%{http_code}' https://multi.test.dev --resolve multi.test.dev:443:172.28.0.10 2>/dev/null)
test_result "Direct proxy returns 200 (no SSO)" "$T3_CODE" "200"

echo "[T4] multi.test.dev - sticky session cookie"
T4_COOKIE=$(docker exec test-client curl -sk -D- https://multi.test.dev --resolve multi.test.dev:443:172.28.0.10 2>/dev/null | grep -i "set-cookie.*p_sticky" || echo "")
test_result "Sticky session cookie p_sticky present" "$([ -n "$T4_COOKIE" ] && echo yes || echo no)" "yes"

echo "[T5] pathtest.test.dev - /api path routing"
T5_BODY=$(docker exec test-client curl -sk https://pathtest.test.dev/api/ --resolve pathtest.test.dev:443:172.28.0.10 2>/dev/null)
T5_OK=$(echo "$T5_BODY" | grep -c "Backend\|html" || true)
test_result "/api path routes to backend" "$([ "$T5_OK" -gt 0 ] && echo yes || echo no)" "yes"

echo "[T6] pathtest.test.dev - catch-all path"
T6_BODY=$(docker exec test-client curl -sk https://pathtest.test.dev/ --resolve pathtest.test.dev:443:172.28.0.10 2>/dev/null)
T6_OK=$(echo "$T6_BODY" | grep -c "Backend\|Secondary\|html" || true)
test_result "Catch-all routes to backend" "$([ "$T6_OK" -gt 0 ] && echo yes || echo no)" "yes"

echo "[T7] headers.test.dev - SSO redirect with postAuthPath"
T7_LOC=$(docker exec test-client curl -sk -D- -o /dev/null https://headers.test.dev/some/page --resolve headers.test.dev:443:172.28.0.10 2>/dev/null | grep -i "^location:" || echo "")
T7_HAS_DASHBOARD=$(echo "$T7_LOC" | grep -c "dashboard" || true)
test_result "SSO redirect uses postAuthPath=/dashboard" "$([ "$T7_HAS_DASHBOARD" -gt 0 ] && echo yes || echo no)" "yes"

echo "[T8] Newt config - checking for new fields in auth proxy config"
T8_TARGETS=$(docker logs test-newt 2>&1 | grep -c "targets:\[" 2>/dev/null || true)
T8_STICKY=$(docker logs test-newt 2>&1 | grep -c "stickySession:" 2>/dev/null || true)
test_result "Targets array in config" "$([ "${T8_TARGETS:-0}" -gt 0 ] && echo yes || echo no)" "yes"
test_result "stickySession field in config" "$([ "${T8_STICKY:-0}" -gt 0 ] && echo yes || echo no)" "yes"

echo "[T9] Newt resource count"
T9_LAST=$(docker logs test-newt 2>&1 | grep "Replaced resource set" | tail -1)
T9_COUNT=$(echo "$T9_LAST" | grep -oE '[0-9]+ resources' | grep -oE '[0-9]+' || echo "0")
test_result "Newt has 6 resources loaded" "$([ "$T9_COUNT" -ge 6 ] && echo yes || echo no)" "yes"

echo "[T10] intelligent.test.dev - intelligent routing returns one healthy IP"
T10_LINES=$(echo "$RESULT_INTEL" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | wc -l | tr -d ' ')
T10_VALID=$(echo "$RESULT_INTEL" | grep -E '^(172\.28\.0\.10|172\.28\.0\.11)$' >/dev/null && echo yes || echo no)
test_result "Intelligent routing returns a single A record" "$([ "$T10_LINES" -eq 1 ] && echo yes || echo no)" "yes"
test_result "Intelligent routing answer is a known healthy site IP" "$T10_VALID" "yes"

echo "[T11] stickycross.test.dev - sticky DNS affinity follows last established session"
docker exec test-client curl -sk -o /dev/null https://stickycross.test.dev --resolve stickycross.test.dev:443:172.28.0.10 2>/dev/null || true
sleep 1
T11_DNS_N1=$(docker exec test-client sh -lc "dig @172.28.0.10 stickycross.test.dev A +short | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1" 2>/dev/null | tr -d '\r')
test_result "After session on Newt 1, DNS via Newt 1 returns site 1 IP" "$T11_DNS_N1" "172.28.0.10"

docker exec test-client curl -sk -o /dev/null https://stickycross.test.dev --resolve stickycross.test.dev:443:172.28.0.11 2>/dev/null || true
sleep 1
T11_DNS_N2=$(docker exec test-client sh -lc "dig @172.28.0.11 stickycross.test.dev A +short | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1" 2>/dev/null | tr -d '\r')
test_result "After session on Newt 2, DNS via Newt 2 returns site 2 IP" "$T11_DNS_N2" "172.28.0.11"

echo "[T12] intelligent.test.dev - sticky affinity overrides intelligent selection"
docker exec test-client curl -sk -o /dev/null https://intelligent.test.dev --resolve intelligent.test.dev:443:172.28.0.11 2>/dev/null || true
sleep 1
T12_DNS=$(docker exec test-client sh -lc "dig @172.28.0.11 intelligent.test.dev A +short | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1" 2>/dev/null | tr -d '\r')
test_result "After session on Newt 2, intelligent policy via Newt 2 returns site 2 IP" "$T12_DNS" "172.28.0.11"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "Some bootstrap integration checks failed. Debug with:"
    echo "  docker logs test-newt 2>&1 | grep -i 'auth proxy'"
    echo "  docker logs test-pangolin 2>&1 | grep -i 'auth proxy'"
fi
