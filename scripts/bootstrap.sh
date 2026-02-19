#!/usr/bin/env bash
# Bootstrap script for Pangolin DNS Authority test stack
# This creates the initial admin, org, site, domain, resource, and target
# so that Newt can connect and DNS Authority can be tested.

set -euo pipefail

BASE="http://localhost:3001/api/v1"
COOKIES="/tmp/pangolin-cookies.txt"

echo "=== Pangolin DNS Authority Test Bootstrap ==="
echo ""

# Step 1: Wait for Pangolin to be ready
echo "[1/8] Waiting for Pangolin API..."
for i in $(seq 1 60); do
    if curl -s "$BASE/auth/initial-setup-complete" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

# Step 2: Check if setup is already complete
SETUP_COMPLETE=$(curl -s "$BASE/auth/initial-setup-complete" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['complete'])" 2>/dev/null || echo "error")
if [ "$SETUP_COMPLETE" = "True" ]; then
    echo "    Setup already complete. Logging in..."
    curl -s -X POST "$BASE/auth/login" \
        -H "Content-Type: application/json" \
        -c "$COOKIES" \
        -d '{"email":"admin@test.dev","password":"TestAdmin123!"}' >/dev/null
    echo "    Logged in."
else
    # Step 3: Get setup token from Pangolin logs
    echo "[2/8] Getting setup token from Pangolin logs..."
    SETUP_TOKEN=$(docker logs test-pangolin 2>&1 | grep "^Token:" | tail -1 | awk '{print $2}')
    if [ -z "$SETUP_TOKEN" ]; then
        echo "ERROR: Could not find setup token in Pangolin logs"
        echo "Check: docker logs test-pangolin 2>&1 | grep Token"
        exit 1
    fi
    echo "    Token: $SETUP_TOKEN"

    # Step 4: Create server admin
    echo "[3/8] Creating server admin..."
    curl -s -X PUT "$BASE/auth/set-server-admin" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"admin@test.dev\",\"password\":\"TestAdmin123!\",\"setupToken\":\"$SETUP_TOKEN\"}" >/dev/null
    echo "    Admin created: admin@test.dev"

    # Step 5: Login
    echo "[4/8] Logging in..."
    curl -s -X POST "$BASE/auth/login" \
        -H "Content-Type: application/json" \
        -c "$COOKIES" \
        -d '{"email":"admin@test.dev","password":"TestAdmin123!"}' >/dev/null
    echo "    Logged in."
fi

# Step 6: Create org (skip if exists)
echo "[5/8] Creating organization..."
ORG_EXISTS=$(curl -s -b "$COOKIES" "$BASE/org/test-org" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")
if [ "$ORG_EXISTS" = "True" ]; then
    echo "    Org 'test-org' already exists, skipping."
else
    DEFAULTS=$(curl -s -b "$COOKIES" "$BASE/pick-org-defaults")
    SUBNET=$(echo "$DEFAULTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['subnet'])")
    UTIL_SUBNET=$(echo "$DEFAULTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['utilitySubnet'])")
    curl -s -X PUT -b "$COOKIES" "$BASE/org" \
        -H "Content-Type: application/json" \
        -d "{\"orgId\":\"test-org\",\"name\":\"Test Organization\",\"subnet\":\"$SUBNET\",\"utilitySubnet\":\"$UTIL_SUBNET\"}" >/dev/null
    echo "    Org created: test-org"
fi

# Step 7: Create site (skip if exists)
echo "[6/8] Creating site with Newt credentials..."
SITE_EXISTS=$(curl -s -b "$COOKIES" "$BASE/site/1" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")
if [ "$SITE_EXISTS" = "True" ]; then
    echo "    Site already exists, updating DNS Authority settings..."
    curl -s -X POST -b "$COOKIES" "$BASE/site/1" \
        -H "Content-Type: application/json" \
        -d '{"dnsAuthorityEnabled":true,"publicIp":"172.28.0.10"}' >/dev/null
else
    curl -s -X PUT -b "$COOKIES" "$BASE/org/test-org/site" \
        -H "Content-Type: application/json" \
        -d '{"name":"Test Site","type":"newt","newtId":"test-newt-001","secret":"test-secret-for-local-development-only"}' >/dev/null
    echo "    Site created with Newt ID: test-newt-001"

    # Enable DNS Authority and set publicIp
    curl -s -X POST -b "$COOKIES" "$BASE/site/1" \
        -H "Content-Type: application/json" \
        -d '{"dnsAuthorityEnabled":true,"publicIp":"172.28.0.10"}' >/dev/null
    echo "    DNS Authority enabled, publicIp: 172.28.0.10"
fi

# Step 7b: Create secondary site (skip if exists)
echo "[6/8b] Creating secondary site (Newt 2)..."
SITE2_EXISTS=$(curl -s -b "$COOKIES" "$BASE/site/2" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")
if [ "$SITE2_EXISTS" = "True" ]; then
    echo "    Secondary site already exists, updating DNS Authority settings..."
    curl -s -X POST -b "$COOKIES" "$BASE/site/2" \
        -H "Content-Type: application/json" \
        -d '{"dnsAuthorityEnabled":true,"publicIp":"172.28.0.11"}' >/dev/null
else
    curl -s -X PUT -b "$COOKIES" "$BASE/org/test-org/site" \
        -H "Content-Type: application/json" \
        -d '{"name":"Test Site Secondary","type":"newt","newtId":"test-newt-002","secret":"test-secret-for-local-development-only"}' >/dev/null
    echo "    Secondary site created with Newt ID: test-newt-002"

    # Enable DNS Authority and set publicIp
    curl -s -X POST -b "$COOKIES" "$BASE/site/2" \
        -H "Content-Type: application/json" \
        -d '{"dnsAuthorityEnabled":true,"publicIp":"172.28.0.11"}' >/dev/null
    echo "    DNS Authority enabled on secondary site, publicIp: 172.28.0.11"
fi

# Step 8: Create resource (skip if exists)
echo "[7/8] Creating resource app.test.dev..."
RESOURCE_EXISTS=$(curl -s -b "$COOKIES" "$BASE/resource/1" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")
if [ "$RESOURCE_EXISTS" = "True" ]; then
    echo "    Resource already exists, ensuring DNS Authority enabled..."
    curl -s -X POST -b "$COOKIES" "$BASE/resource/1" \
        -H "Content-Type: application/json" \
        -d '{"dnsAuthorityEnabled":true,"dnsAuthorityTtl":60,"dnsAuthorityRoutingPolicy":"roundrobin"}' >/dev/null

    # Try adding secondary target if it might be missing
    echo "    Ensuring secondary target exists..."
    curl -s -X PUT -b "$COOKIES" "$BASE/resource/1/target" \
        -H "Content-Type: application/json" \
        -d '{"siteId":2,"ip":"172.28.0.21","port":80,"method":"http","enabled":true}' >/dev/null || true
else
    curl -s -X PUT -b "$COOKIES" "$BASE/org/test-org/resource" \
        -H "Content-Type: application/json" \
        -d '{"name":"App","http":true,"protocol":"tcp","domainId":"test-domain","subdomain":"app"}' >/dev/null
    echo "    Resource created: app.test.dev"

    # Add target
    curl -s -X PUT -b "$COOKIES" "$BASE/resource/1/target" \
        -H "Content-Type: application/json" \
        -d '{"siteId":1,"ip":"172.28.0.20","port":80,"method":"http","enabled":true}' >/dev/null
    echo "    Target added: 172.28.0.20:80 (backend)"

    # Add secondary target
    curl -s -X PUT -b "$COOKIES" "$BASE/resource/1/target" \
        -H "Content-Type: application/json" \
        -d '{"siteId":2,"ip":"172.28.0.21","port":80,"method":"http","enabled":true}' >/dev/null
    echo "    Target added: 172.28.0.21:80 (secondary backend)"

    # Enable DNS Authority
    curl -s -X POST -b "$COOKIES" "$BASE/resource/1" \
        -H "Content-Type: application/json" \
        -d '{"dnsAuthorityEnabled":true,"dnsAuthorityTtl":60,"dnsAuthorityRoutingPolicy":"roundrobin"}' >/dev/null
    echo "    DNS Authority enabled on resource"
fi

echo ""
echo "[8/8] Waiting for Newt to connect and receive DNS zones..."
sleep 8

echo "    Waiting for DNS Authority listeners (Newt 1:5353, Newt 2:5354)..."
wait_for_dns_listener() {
    local port="$1"
    local name="$2"
    local ok="false"

    for _ in $(seq 1 30); do
        if dig @localhost -p "$port" app.test.dev A +short +time=1 +tries=1 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            ok="true"
            break
        fi
        sleep 1
    done

    if [ "$ok" = "true" ]; then
        echo "    $name DNS is ready"
    else
        echo "    WARN: $name DNS did not answer within timeout; continuing tests"
    fi
}

wait_for_dns_listener 5353 "Newt 1"
wait_for_dns_listener 5354 "Newt 2"

# ===================================================================
# Auth Proxy Feature Tests
# Create additional resources to exercise: multi-target with LB,
# sticky sessions, path routing, custom headers, host header override,
# postAuthPath, and non-SSO passthrough.
# ===================================================================

echo ""
echo "=== Creating Auth Proxy Test Resources ==="

# --- Resource 2: multi-target with sticky sessions (no SSO) ---
echo "[AP-1] Creating multi.test.dev (multi-target + stickySession, no SSO)..."
RESOURCE2_EXISTS=$(curl -s -b "$COOKIES" "$BASE/resource/2" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")
if [ "$RESOURCE2_EXISTS" != "True" ]; then
    curl -s -X PUT -b "$COOKIES" "$BASE/org/test-org/resource" \
        -H "Content-Type: application/json" \
        -d '{"name":"Multi Target","http":true,"protocol":"tcp","domainId":"test-domain","subdomain":"multi"}' >/dev/null
    # Add primary target
    curl -s -X PUT -b "$COOKIES" "$BASE/resource/2/target" \
        -H "Content-Type: application/json" \
        -d '{"siteId":1,"ip":"172.28.0.20","port":80,"method":"http","enabled":true,"priority":50}' >/dev/null
    # Add secondary target
    curl -s -X PUT -b "$COOKIES" "$BASE/resource/2/target" \
        -H "Content-Type: application/json" \
        -d '{"siteId":1,"ip":"172.28.0.21","port":80,"method":"http","enabled":true,"priority":100}' >/dev/null
    # Enable DNS Authority + sticky sessions, SSO off
    curl -s -X POST -b "$COOKIES" "$BASE/resource/2" \
        -H "Content-Type: application/json" \
        -d '{"dnsAuthorityEnabled":true,"dnsAuthorityTtl":60,"dnsAuthorityRoutingPolicy":"roundrobin","stickySession":true,"sso":false}' >/dev/null
    echo "    Created: multi.test.dev (2 targets on site 1, stickySession=true, sso=false)"
else
    echo "    Already exists, skipping."
fi

# --- Resource 3: path routing + rewriting ---
echo "[AP-2] Creating pathtest.test.dev (path routing + strip prefix)..."
RESOURCE3_EXISTS=$(curl -s -b "$COOKIES" "$BASE/resource/3" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")
if [ "$RESOURCE3_EXISTS" != "True" ]; then
    curl -s -X PUT -b "$COOKIES" "$BASE/org/test-org/resource" \
        -H "Content-Type: application/json" \
        -d '{"name":"Path Test","http":true,"protocol":"tcp","domainId":"test-domain","subdomain":"pathtest"}' >/dev/null
    # Target with prefix path + stripPrefix rewrite
    curl -s -X PUT -b "$COOKIES" "$BASE/resource/3/target" \
        -H "Content-Type: application/json" \
        -d '{"siteId":1,"ip":"172.28.0.20","port":80,"method":"http","enabled":true,"path":"/api","pathMatchType":"prefix","rewritePath":null,"rewritePathType":"stripPrefix","priority":10}' >/dev/null
    # Catch-all target (lower priority)
    curl -s -X PUT -b "$COOKIES" "$BASE/resource/3/target" \
        -H "Content-Type: application/json" \
        -d '{"siteId":1,"ip":"172.28.0.21","port":80,"method":"http","enabled":true,"priority":100}' >/dev/null
    # Enable DNS Authority, SSO off
    curl -s -X POST -b "$COOKIES" "$BASE/resource/3" \
        -H "Content-Type: application/json" \
        -d '{"dnsAuthorityEnabled":true,"dnsAuthorityTtl":60,"dnsAuthorityRoutingPolicy":"roundrobin","sso":false}' >/dev/null
    echo "    Created: pathtest.test.dev (/api->stripPrefix to backend-1, catch-all to backend-2)"
else
    echo "    Already exists, skipping."
fi

# --- Resource 4: custom headers + setHostHeader + postAuthPath ---
echo "[AP-3] Creating headers.test.dev (custom headers + setHostHeader)..."
RESOURCE4_EXISTS=$(curl -s -b "$COOKIES" "$BASE/resource/4" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")
if [ "$RESOURCE4_EXISTS" != "True" ]; then
    curl -s -X PUT -b "$COOKIES" "$BASE/org/test-org/resource" \
        -H "Content-Type: application/json" \
        -d '{"name":"Headers Test","http":true,"protocol":"tcp","domainId":"test-domain","subdomain":"headers"}' >/dev/null
    curl -s -X PUT -b "$COOKIES" "$BASE/resource/4/target" \
        -H "Content-Type: application/json" \
        -d '{"siteId":1,"ip":"172.28.0.20","port":80,"method":"http","enabled":true}' >/dev/null
    # Enable DNS Authority + custom headers + setHostHeader + postAuthPath, SSO on
    curl -s -X POST -b "$COOKIES" "$BASE/resource/4" \
        -H "Content-Type: application/json" \
        -d '{"dnsAuthorityEnabled":true,"dnsAuthorityTtl":60,"dnsAuthorityRoutingPolicy":"roundrobin","sso":true,"setHostHeader":"backend.internal","headers":[{"name":"X-Custom-Test","value":"hello-from-pangolin"},{"name":"X-Environment","value":"testing"}],"postAuthPath":"/dashboard"}' >/dev/null
    echo "    Created: headers.test.dev (setHostHeader=backend.internal, 2 custom headers, postAuthPath=/dashboard)"
else
    echo "    Already exists, skipping."
fi

# --- Resource 5: intelligent DNS routing with health checks ---
echo "[AP-4] Creating intelligent.test.dev (intelligent routing + health checks)..."
RESOURCE5_EXISTS=$(curl -s -b "$COOKIES" "$BASE/resource/5" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")
if [ "$RESOURCE5_EXISTS" != "True" ]; then
    curl -s -X PUT -b "$COOKIES" "$BASE/org/test-org/resource" \
        -H "Content-Type: application/json" \
        -d '{"name":"Intelligent DNS","http":true,"protocol":"tcp","domainId":"test-domain","subdomain":"intelligent"}' >/dev/null

    curl -s -X PUT -b "$COOKIES" "$BASE/resource/5/target" \
        -H "Content-Type: application/json" \
        -d '{"siteId":1,"ip":"172.28.0.20","port":80,"method":"http","enabled":true,"priority":50,"hcEnabled":true,"hcScheme":"http","hcHostname":"172.28.0.20","hcPort":80,"hcPath":"/","hcMethod":"GET","hcInterval":5,"hcUnhealthyInterval":5,"hcTimeout":2}' >/dev/null

    curl -s -X PUT -b "$COOKIES" "$BASE/resource/5/target" \
        -H "Content-Type: application/json" \
        -d '{"siteId":2,"ip":"172.28.0.21","port":80,"method":"http","enabled":true,"priority":100,"hcEnabled":true,"hcScheme":"http","hcHostname":"172.28.0.21","hcPort":80,"hcPath":"/","hcMethod":"GET","hcInterval":5,"hcUnhealthyInterval":5,"hcTimeout":2}' >/dev/null

    curl -s -X POST -b "$COOKIES" "$BASE/resource/5" \
        -H "Content-Type: application/json" \
        -d '{"dnsAuthorityEnabled":true,"dnsAuthorityTtl":60,"dnsAuthorityRoutingPolicy":"intelligent","stickySession":true,"sso":false}' >/dev/null
    echo "    Created: intelligent.test.dev (policy=intelligent, health checks enabled, stickySession=true)"
else
    echo "    Already exists, ensuring intelligent routing is configured..."
    curl -s -X POST -b "$COOKIES" "$BASE/resource/5" \
        -H "Content-Type: application/json" \
        -d '{"dnsAuthorityEnabled":true,"dnsAuthorityTtl":60,"dnsAuthorityRoutingPolicy":"intelligent","stickySession":true,"sso":false}' >/dev/null || true
fi

# --- Resource 6: cross-site sticky DNS affinity (roundrobin + sticky) ---
echo "[AP-5] Creating stickycross.test.dev (cross-site sticky DNS affinity)..."
RESOURCE6_EXISTS=$(curl -s -b "$COOKIES" "$BASE/resource/6" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")
if [ "$RESOURCE6_EXISTS" != "True" ]; then
    curl -s -X PUT -b "$COOKIES" "$BASE/org/test-org/resource" \
        -H "Content-Type: application/json" \
        -d '{"name":"Sticky Cross Site","http":true,"protocol":"tcp","domainId":"test-domain","subdomain":"stickycross"}' >/dev/null

    curl -s -X PUT -b "$COOKIES" "$BASE/resource/6/target" \
        -H "Content-Type: application/json" \
        -d '{"siteId":1,"ip":"172.28.0.20","port":80,"method":"http","enabled":true,"priority":50}' >/dev/null

    curl -s -X PUT -b "$COOKIES" "$BASE/resource/6/target" \
        -H "Content-Type: application/json" \
        -d '{"siteId":2,"ip":"172.28.0.21","port":80,"method":"http","enabled":true,"priority":100}' >/dev/null

    curl -s -X POST -b "$COOKIES" "$BASE/resource/6" \
        -H "Content-Type: application/json" \
        -d '{"dnsAuthorityEnabled":true,"dnsAuthorityTtl":60,"dnsAuthorityRoutingPolicy":"roundrobin","stickySession":true,"sso":false}' >/dev/null
    echo "    Created: stickycross.test.dev (targets on site 1 + site 2, stickySession=true)"
else
    echo "    Already exists, ensuring sticky cross-site routing is configured..."
    curl -s -X POST -b "$COOKIES" "$BASE/resource/6" \
        -H "Content-Type: application/json" \
        -d '{"dnsAuthorityEnabled":true,"dnsAuthorityTtl":60,"dnsAuthorityRoutingPolicy":"roundrobin","stickySession":true,"sso":false}' >/dev/null || true
fi

echo ""
echo "Waiting for auth proxy configs to propagate..."
sleep 5

# Verify DNS Authority
echo ""
echo "=== DNS Authority Verification ==="
echo ""

RESULT_APP=$(dig @localhost -p 5353 app.test.dev A +short 2>/dev/null || echo "FAILED")
RESULT_APP2=$(dig @localhost -p 5354 app.test.dev A +short 2>/dev/null || echo "FAILED")
RESULT_WILD=$(dig @localhost -p 5353 random.test.dev A +short 2>/dev/null || echo "FAILED")
RESULT_MULTI=$(dig @localhost -p 5353 multi.test.dev A +short 2>/dev/null || echo "FAILED")
RESULT_PATH=$(dig @localhost -p 5353 pathtest.test.dev A +short 2>/dev/null || echo "FAILED")
RESULT_HDRS=$(dig @localhost -p 5353 headers.test.dev A +short 2>/dev/null || echo "FAILED")
RESULT_INTEL=$(dig @localhost -p 5353 intelligent.test.dev A +short 2>/dev/null || echo "FAILED")
RESULT_STICKYCROSS=$(dig @localhost -p 5353 stickycross.test.dev A +short 2>/dev/null || echo "FAILED")

echo "  app.test.dev (Newt 1)      -> ${RESULT_APP:-EMPTY}"
echo "  app.test.dev (Newt 2)      -> ${RESULT_APP2:-EMPTY}"
echo "  random.test.dev            -> ${RESULT_WILD:-EMPTY}"
echo "  multi.test.dev (Newt 1)    -> ${RESULT_MULTI:-EMPTY}"
echo "  pathtest.test.dev (Newt 1) -> ${RESULT_PATH:-EMPTY}"
echo "  headers.test.dev (Newt 1)  -> ${RESULT_HDRS:-EMPTY}"
echo "  intelligent.test.dev       -> ${RESULT_INTEL:-EMPTY}"
echo "  stickycross.test.dev       -> ${RESULT_STICKYCROSS:-EMPTY}"
echo ""

# ===================================================================
# Auth Proxy Integration Tests
# ===================================================================
echo "=== Auth Proxy Integration Tests ==="
echo ""
PASS=0
FAIL=0

# Helper: test and report
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

# Test 1: app.test.dev SSO redirect (HTTPS)
echo "[T1] app.test.dev — SSO redirect on HTTPS"
T1_CODE=$(docker exec test-client curl -sk -o /dev/null -w '%{http_code}' https://app.test.dev --resolve app.test.dev:443:172.28.0.10 2>/dev/null)
test_result "HTTPS SSO redirect returns 302" "$T1_CODE" "302"

# Test 2: app.test.dev HTTP→HTTPS redirect
echo "[T2] app.test.dev — HTTP→HTTPS redirect"
T2_CODE=$(docker exec test-client curl -s -o /dev/null -w '%{http_code}' http://app.test.dev --resolve app.test.dev:80:172.28.0.10 2>/dev/null)
test_result "HTTP→HTTPS redirect returns 301" "$T2_CODE" "301"

# Test 3: multi.test.dev — no SSO, should proxy directly to backend
echo "[T3] multi.test.dev — direct proxy (no SSO)"
T3_CODE=$(docker exec test-client curl -sk -o /dev/null -w '%{http_code}' https://multi.test.dev --resolve multi.test.dev:443:172.28.0.10 2>/dev/null)
test_result "Direct proxy returns 200 (no SSO)" "$T3_CODE" "200"

# Test 4: multi.test.dev — sticky session cookie set
echo "[T4] multi.test.dev — sticky session cookie"
T4_COOKIE=$(docker exec test-client curl -sk -D- https://multi.test.dev --resolve multi.test.dev:443:172.28.0.10 2>/dev/null | grep -i "set-cookie.*p_sticky" || echo "")
test_result "Sticky session cookie p_sticky present" "$([ -n "$T4_COOKIE" ] && echo yes || echo no)" "yes"

# Test 5: pathtest.test.dev — /api path routes to backend-1
echo "[T5] pathtest.test.dev — /api path routing"
T5_BODY=$(docker exec test-client curl -sk https://pathtest.test.dev/api/ --resolve pathtest.test.dev:443:172.28.0.10 2>/dev/null)
T5_OK=$(echo "$T5_BODY" | grep -c "Backend\|html" || true)
test_result "/api path routes to backend" "$([ "$T5_OK" -gt 0 ] && echo yes || echo no)" "yes"

# Test 6: pathtest.test.dev — catch-all routes to backend-2
echo "[T6] pathtest.test.dev — catch-all path"
T6_BODY=$(docker exec test-client curl -sk https://pathtest.test.dev/ --resolve pathtest.test.dev:443:172.28.0.10 2>/dev/null)
T6_OK=$(echo "$T6_BODY" | grep -c "Backend\|Secondary\|html" || true)
test_result "Catch-all routes to backend" "$([ "$T6_OK" -gt 0 ] && echo yes || echo no)" "yes"

# Test 7: headers.test.dev — SSO redirect includes postAuthPath
echo "[T7] headers.test.dev — SSO redirect with postAuthPath"
T7_LOC=$(docker exec test-client curl -sk -D- -o /dev/null https://headers.test.dev/some/page --resolve headers.test.dev:443:172.28.0.10 2>/dev/null | grep -i "^location:" || echo "")
T7_HAS_DASHBOARD=$(echo "$T7_LOC" | grep -c "dashboard" || true)
test_result "SSO redirect uses postAuthPath=/dashboard" "$([ "$T7_HAS_DASHBOARD" -gt 0 ] && echo yes || echo no)" "yes"

# Test 8: Verify Newt received the expanded config with new fields
echo "[T8] Newt config — checking for new fields in auth proxy config"
T8_TARGETS=$(docker logs test-newt 2>&1 | grep -c "targets:\[" 2>/dev/null || true)
T8_STICKY=$(docker logs test-newt 2>&1 | grep -c "stickySession:" 2>/dev/null || true)
test_result "Targets array in config" "$([ "${T8_TARGETS:-0}" -gt 0 ] && echo yes || echo no)" "yes"
test_result "stickySession field in config" "$([ "${T8_STICKY:-0}" -gt 0 ] && echo yes || echo no)" "yes"

# Test 9: Verify multiple resources received by Newt
echo "[T9] Newt resource count"
T9_LAST=$(docker logs test-newt 2>&1 | grep "Replaced resource set" | tail -1)
T9_COUNT=$(echo "$T9_LAST" | grep -oP '\d+ resources' | grep -oP '\d+' || echo "0")
test_result "Newt has 6 resources loaded" "$([ "$T9_COUNT" -ge 6 ] && echo yes || echo no)" "yes"

# Test 10: intelligent.test.dev returns one valid DNS A answer
echo "[T10] intelligent.test.dev — intelligent routing returns one healthy IP"
T10_LINES=$(echo "$RESULT_INTEL" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | wc -l | tr -d ' ')
T10_VALID=$(echo "$RESULT_INTEL" | grep -E '^(172\.28\.0\.10|172\.28\.0\.11)$' >/dev/null && echo yes || echo no)
test_result "Intelligent routing returns a single A record" "$([ "$T10_LINES" -eq 1 ] && echo yes || echo no)" "yes"
test_result "Intelligent routing answer is a known healthy site IP" "$T10_VALID" "yes"

# Test 11: sticky DNS affinity for roundrobin policy (stickycross.test.dev)
echo "[T11] stickycross.test.dev — sticky DNS affinity follows last established session"
# Establish session through Newt 1, then query Newt 1 DNS from same client
docker exec test-client curl -sk -o /dev/null https://stickycross.test.dev --resolve stickycross.test.dev:443:172.28.0.10 2>/dev/null || true
sleep 1
T11_DNS_N1=$(docker exec test-client sh -lc "dig @172.28.0.10 stickycross.test.dev A +short | grep -E '^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$' | head -n1" 2>/dev/null | tr -d '\r')
test_result "After session on Newt 1, DNS via Newt 1 returns site 1 IP" "$T11_DNS_N1" "172.28.0.10"

# Establish session through Newt 2, then query Newt 2 DNS from same client
docker exec test-client curl -sk -o /dev/null https://stickycross.test.dev --resolve stickycross.test.dev:443:172.28.0.11 2>/dev/null || true
sleep 1
T11_DNS_N2=$(docker exec test-client sh -lc "dig @172.28.0.11 stickycross.test.dev A +short | grep -E '^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$' | head -n1" 2>/dev/null | tr -d '\r')
test_result "After session on Newt 2, DNS via Newt 2 returns site 2 IP" "$T11_DNS_N2" "172.28.0.11"

# Test 12: sticky DNS affinity also applies to intelligent policy
echo "[T12] intelligent.test.dev — sticky affinity overrides intelligent selection"
docker exec test-client curl -sk -o /dev/null https://intelligent.test.dev --resolve intelligent.test.dev:443:172.28.0.11 2>/dev/null || true
sleep 1
T12_DNS=$(docker exec test-client sh -lc "dig @172.28.0.11 intelligent.test.dev A +short | grep -E '^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$' | head -n1" 2>/dev/null | tr -d '\r')
test_result "After session on Newt 2, intelligent policy via Newt 2 returns site 2 IP" "$T12_DNS" "172.28.0.11"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "Some tests failed. Debug with:"
    echo "  docker logs test-newt 2>&1 | grep -i 'auth proxy'"
    echo "  docker logs test-pangolin 2>&1 | grep -i 'auth proxy'"
fi
