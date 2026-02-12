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

# Step 8: Create resource (skip if exists)
echo "[7/8] Creating resource app.test.dev..."
RESOURCE_EXISTS=$(curl -s -b "$COOKIES" "$BASE/resource/1" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")
if [ "$RESOURCE_EXISTS" = "True" ]; then
    echo "    Resource already exists, ensuring DNS Authority enabled..."
    curl -s -X POST -b "$COOKIES" "$BASE/resource/1" \
        -H "Content-Type: application/json" \
        -d '{"dnsAuthorityEnabled":true,"dnsAuthorityTtl":60,"dnsAuthorityRoutingPolicy":"failover"}' >/dev/null
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

    # Enable DNS Authority
    curl -s -X POST -b "$COOKIES" "$BASE/resource/1" \
        -H "Content-Type: application/json" \
        -d '{"dnsAuthorityEnabled":true,"dnsAuthorityTtl":60,"dnsAuthorityRoutingPolicy":"failover"}' >/dev/null
    echo "    DNS Authority enabled on resource"
fi

echo ""
echo "[8/8] Waiting for Newt to connect and receive DNS zones..."
sleep 8

# Verify DNS Authority
echo ""
echo "=== DNS Authority Verification ==="
echo ""

RESULT_APP=$(dig @localhost -p 5353 app.test.dev A +short 2>/dev/null || echo "FAILED")
RESULT_WILD=$(dig @localhost -p 5353 random.test.dev A +short 2>/dev/null || echo "FAILED")

echo "  app.test.dev     -> ${RESULT_APP:-EMPTY}"
echo "  random.test.dev  -> ${RESULT_WILD:-EMPTY}"
echo ""

if [ "$RESULT_APP" = "172.28.0.10" ] && [ "$RESULT_WILD" = "172.28.0.10" ]; then
    echo "SUCCESS: DNS Authority is working!"
    echo "  - Resource zone (app.test.dev) resolves correctly"
    echo "  - Wildcard domain zone (*.test.dev) resolves correctly"
else
    echo "WARNING: DNS resolution may not be fully working yet."
    echo "  Check: docker logs test-newt 2>&1 | grep -i dns"
    echo "  Check: docker logs test-pangolin 2>&1 | grep -i dns"
fi

echo ""
echo "=== Test Commands ==="
echo "  dig @localhost -p 5353 app.test.dev A +short"
echo "  dig @localhost -p 5353 anything.test.dev A +short"
echo "  dig @localhost -p 5353 foo.bar.test.dev A +short"
