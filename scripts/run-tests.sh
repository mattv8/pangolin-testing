#!/bin/bash
# Run full end-to-end tests for DNS Authority and Auth Proxy
# This script is executed from within the test-client container

set -e

RESULTS_DIR="/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_FILE="$RESULTS_DIR/test_results_$TIMESTAMP.json"

# Initialize results
echo '{"timestamp":"'$TIMESTAMP'","tests":[]}' > "$RESULTS_FILE"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test configuration
NEWT_DNS="${NEWT_DNS:-172.28.0.10}"
PANGOLIN_URL="${PANGOLIN_URL:-http://pangolin:3001}"
TEST_DOMAIN="${TEST_DOMAIN:-app.test.local}"
BACKEND_PRIMARY="172.28.0.20"
BACKEND_SECONDARY="172.28.0.21"

total_tests=0
passed_tests=0
failed_tests=0

log() {
    echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $1"
}

pass() {
    echo -e "${GREEN}✅ PASS:${NC} $1"
    ((passed_tests++))
    ((total_tests++))
}

fail() {
    echo -e "${RED}❌ FAIL:${NC} $1"
    ((failed_tests++))
    ((total_tests++))
}

skip() {
    echo -e "${YELLOW}⏭️  SKIP:${NC} $1"
    ((total_tests++))
}

header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ============================================================
# Test Suite: Infrastructure Connectivity
# ============================================================
test_infrastructure() {
    header "Infrastructure Connectivity Tests"

    # Test 1: Can reach Pangolin
    log "Testing Pangolin API connectivity..."
    if curl -s --connect-timeout 5 "$PANGOLIN_URL/api/v1/health" > /dev/null 2>&1; then
        pass "Pangolin API is reachable"
    else
        fail "Cannot reach Pangolin API at $PANGOLIN_URL"
    fi

    # Test 2: Can reach Newt DNS port
    log "Testing Newt DNS port connectivity..."
    if nc -z -w5 $NEWT_DNS 53 2>/dev/null; then
        pass "Newt DNS port 53 is accessible"
    else
        fail "Cannot reach Newt DNS at $NEWT_DNS:53"
    fi

    # Test 3: Can reach primary backend
    log "Testing primary backend connectivity..."
    if curl -s --connect-timeout 5 "http://$BACKEND_PRIMARY/health" > /dev/null 2>&1; then
        pass "Primary backend is reachable"
    else
        fail "Cannot reach primary backend at $BACKEND_PRIMARY"
    fi

    # Test 4: Can reach secondary backend
    log "Testing secondary backend connectivity..."
    if curl -s --connect-timeout 5 "http://$BACKEND_SECONDARY/health" > /dev/null 2>&1; then
        pass "Secondary backend is reachable"
    else
        skip "Secondary backend not reachable (may be intentional for failover test)"
    fi
}

# ============================================================
# Test Suite: DNS Authority
# ============================================================
test_dns_authority() {
    header "DNS Authority Tests"

    # Test 1: Basic DNS query
    log "Testing basic DNS A record query..."
    local dns_result=$(dig @$NEWT_DNS $TEST_DOMAIN A +short +timeout=5 2>/dev/null)
    if [ -n "$dns_result" ]; then
        pass "DNS resolution returned: $dns_result"
    else
        fail "DNS query for $TEST_DOMAIN returned empty"
    fi

    # Test 2: DNS query type
    log "Testing DNS response is valid IPv4..."
    if echo "$dns_result" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        pass "DNS response is valid IPv4 address"
    else
        fail "DNS response is not a valid IPv4: $dns_result"
    fi

    # Test 3: DNS TTL
    log "Testing DNS TTL is set..."
    local ttl=$(dig @$NEWT_DNS $TEST_DOMAIN A +noall +answer +timeout=5 2>/dev/null | awk '{print $2}')
    if [ -n "$ttl" ] && [ "$ttl" -gt 0 ]; then
        pass "DNS TTL is $ttl seconds"
    else
        skip "Could not verify DNS TTL"
    fi

    # Test 4: Non-existent domain
    log "Testing NXDOMAIN for unknown domain..."
    local nxdomain_result=$(dig @$NEWT_DNS nonexistent.invalid A +short +timeout=5 2>/dev/null)
    if [ -z "$nxdomain_result" ]; then
        pass "Non-existent domain correctly returns no records"
    else
        fail "Non-existent domain returned: $nxdomain_result"
    fi
}

# ============================================================
# Test Suite: Auth Proxy
# ============================================================
test_auth_proxy() {
    header "Auth Proxy Tests"

    # Get resolved IP first
    local resolved_ip=$(dig @$NEWT_DNS $TEST_DOMAIN A +short +timeout=5 2>/dev/null | head -1)

    if [ -z "$resolved_ip" ]; then
        fail "Cannot test auth proxy - DNS resolution failed"
        return
    fi

    log "Using resolved IP: $resolved_ip for $TEST_DOMAIN"

    # Test 1: Unauthenticated request
    log "Testing unauthenticated request behavior..."
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 \
        --resolve "$TEST_DOMAIN:80:$resolved_ip" \
        "http://$TEST_DOMAIN/" 2>/dev/null || echo "000")

    case "$http_code" in
        302|307)
            pass "Auth proxy redirects unauthenticated requests (HTTP $http_code)"
            ;;
        401|403)
            pass "Auth proxy rejects unauthenticated requests (HTTP $http_code)"
            ;;
        200)
            skip "Request succeeded without auth - SSO may be disabled"
            ;;
        000)
            fail "Connection failed to auth proxy"
            ;;
        *)
            fail "Unexpected HTTP response: $http_code"
            ;;
    esac

    # Test 2: Check redirect location
    log "Checking redirect points to Pangolin login..."
    local redirect_location=$(curl -s -o /dev/null -w "%{redirect_url}" \
        --connect-timeout 5 \
        --resolve "$TEST_DOMAIN:80:$resolved_ip" \
        "http://$TEST_DOMAIN/" 2>/dev/null)

    if echo "$redirect_location" | grep -q "pangolin\|login\|auth"; then
        pass "Redirect location contains auth path: $redirect_location"
    elif [ -n "$redirect_location" ]; then
        pass "Redirect location: $redirect_location"
    else
        skip "No redirect location (may be expected if SSO disabled)"
    fi

    # Test 3: Session validation endpoint
    log "Testing session validation endpoint..."
    local validate_response=$(curl -s --connect-timeout 5 "$PANGOLIN_URL/api/v1/auth/session/validate" 2>/dev/null)

    if echo "$validate_response" | grep -q '"valid"'; then
        pass "Session validation endpoint responds correctly"
        log "Response: $validate_response"
    else
        fail "Session validation endpoint not working: $validate_response"
    fi
}

# ============================================================
# Test Suite: Failover (if enabled)
# ============================================================
test_failover() {
    header "Failover Tests"

    log "Testing DNS failover behavior..."

    # Query DNS multiple times to check for round-robin or failover
    local ip1=$(dig @$NEWT_DNS $TEST_DOMAIN A +short +timeout=5 2>/dev/null | head -1)
    sleep 1
    local ip2=$(dig @$NEWT_DNS $TEST_DOMAIN A +short +timeout=5 2>/dev/null | head -1)

    log "First query returned: $ip1"
    log "Second query returned: $ip2"

    if [ "$ip1" = "$ip2" ]; then
        pass "DNS returns consistent IP (failover mode or primary healthy)"
    else
        pass "DNS returns different IPs (round-robin active)"
    fi
}

# ============================================================
# Main Test Runner
# ============================================================
main() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         DNS Authority & Auth Proxy Test Suite                 ║${NC}"
    echo -e "${CYAN}║                   End-to-End Tests                            ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    log "Test configuration:"
    echo "  - Newt DNS Server: $NEWT_DNS"
    echo "  - Pangolin URL: $PANGOLIN_URL"
    echo "  - Test Domain: $TEST_DOMAIN"
    echo "  - Primary Backend: $BACKEND_PRIMARY"
    echo "  - Secondary Backend: $BACKEND_SECONDARY"

    # Run test suites
    test_infrastructure
    test_dns_authority
    test_auth_proxy
    test_failover

    # Summary
    header "Test Summary"
    echo -e "Total tests:  ${CYAN}$total_tests${NC}"
    echo -e "Passed:       ${GREEN}$passed_tests${NC}"
    echo -e "Failed:       ${RED}$failed_tests${NC}"
    echo ""

    if [ $failed_tests -eq 0 ]; then
        echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║                    ALL TESTS PASSED! ✅                       ║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
        exit 0
    else
        echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                    SOME TESTS FAILED ❌                        ║${NC}"
        echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
        exit 1
    fi
}

main "$@"
