#!/bin/bash
# Test utilities for DNS Authority and Auth Proxy testing

set -e

NEWT_DNS="${NEWT_DNS:-172.28.0.10}"
PANGOLIN_URL="${PANGOLIN_URL:-http://pangolin:3001}"
TEST_DOMAIN="${TEST_DOMAIN:-app.test.local}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

# Test DNS resolution
test_dns() {
    print_header "Testing DNS Resolution"

    echo "Testing DNS query for $TEST_DOMAIN via $NEWT_DNS..."
    echo ""

    if dig @$NEWT_DNS $TEST_DOMAIN A +short +timeout=5; then
        print_success "DNS resolution successful"
    else
        print_error "DNS resolution failed"
        return 1
    fi

    echo ""
    echo "Full DNS response:"
    dig @$NEWT_DNS $TEST_DOMAIN A +noall +answer +timeout=5
}

# Test HTTP without auth
test_http_noauth() {
    print_header "Testing HTTP Without Authentication"

    echo "Requesting http://$TEST_DOMAIN without session cookie..."
    echo ""

    response=$(curl -s -o /dev/null -w "%{http_code}" --resolve "$TEST_DOMAIN:80:$NEWT_DNS" "http://$TEST_DOMAIN/" 2>/dev/null || echo "000")

    if [ "$response" = "302" ] || [ "$response" = "307" ]; then
        print_success "Auth proxy correctly redirects unauthenticated requests (HTTP $response)"
    elif [ "$response" = "401" ]; then
        print_success "Auth proxy correctly rejects unauthenticated requests (HTTP 401)"
    elif [ "$response" = "200" ]; then
        print_warning "Request succeeded without auth - SSO may be disabled for this resource"
    else
        print_error "Unexpected response: HTTP $response"
    fi
}

# Test authentication flow
test_auth_flow() {
    print_header "Testing Authentication Flow"

    echo "1. Getting login page from Pangolin..."
    if curl -s "$PANGOLIN_URL/api/v1/health" > /dev/null; then
        print_success "Pangolin API is reachable"
    else
        print_error "Cannot reach Pangolin API"
        return 1
    fi

    echo ""
    echo "2. Checking session validation endpoint..."
    response=$(curl -s "$PANGOLIN_URL/api/v1/auth/session/validate")
    echo "Response: $response" | jq . 2>/dev/null || echo "$response"
}

# Test full flow with session
test_with_session() {
    local session_token="$1"

    if [ -z "$session_token" ]; then
        print_error "Usage: test-utils session <session_token>"
        return 1
    fi

    print_header "Testing With Session Token"

    echo "Making authenticated request to http://$TEST_DOMAIN..."
    echo ""

    curl -v --resolve "$TEST_DOMAIN:80:$(dig @$NEWT_DNS $TEST_DOMAIN A +short)" \
         -H "Cookie: p_session=$session_token" \
         "http://$TEST_DOMAIN/api/whoami" 2>&1
}

# Run all tests
run_all_tests() {
    print_header "Running Full Test Suite"

    local passed=0
    local failed=0

    echo "Starting comprehensive test suite..."
    echo ""

    # Test 1: DNS
    if test_dns; then
        ((passed++))
    else
        ((failed++))
    fi

    # Test 2: HTTP without auth
    if test_http_noauth; then
        ((passed++))
    else
        ((failed++))
    fi

    # Test 3: Auth flow
    if test_auth_flow; then
        ((passed++))
    else
        ((failed++))
    fi

    echo ""
    print_header "Test Results"
    echo "Passed: $passed"
    echo "Failed: $failed"

    if [ $failed -eq 0 ]; then
        print_success "All tests passed!"
    else
        print_error "Some tests failed"
        return 1
    fi
}

# Show usage
usage() {
    echo "DNS Authority & Auth Proxy Test Utilities"
    echo ""
    echo "Usage: test-utils <command> [args]"
    echo ""
    echo "Commands:"
    echo "  dns           Test DNS resolution via Newt"
    echo "  http          Test HTTP request without authentication"
    echo "  auth          Test authentication flow"
    echo "  session <tok> Test with a session token"
    echo "  all           Run all tests"
    echo "  help          Show this help"
    echo ""
    echo "Environment variables:"
    echo "  NEWT_DNS      Newt DNS server IP (default: 172.28.0.10)"
    echo "  PANGOLIN_URL  Pangolin API URL (default: http://pangolin:3001)"
    echo "  TEST_DOMAIN   Domain to test (default: app.test.local)"
}

# Main
case "${1:-help}" in
    dns)
        test_dns
        ;;
    http)
        test_http_noauth
        ;;
    auth)
        test_auth_flow
        ;;
    session)
        test_with_session "$2"
        ;;
    all)
        run_all_tests
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo "Unknown command: $1"
        usage
        exit 1
        ;;
esac
