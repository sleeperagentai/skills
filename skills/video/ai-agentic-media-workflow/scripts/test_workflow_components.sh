#!/bin/bash
# Script: test_ai_media_workflow.sh
# Purpose: Verify AI agentic media workflow components are functioning

set -euo pipefail

echo "🔍 Testing AI Agentic Media Workflow Components"
echo "=============================================="

# Configuration
BACKEND_URL="http://localhost:8000"
FRONTEND_URL="http://localhost:3000"
TEST_PROMPT="A short test video about artificial intelligence"
TEST_USER_EMAIL="test@example.com"
TEST_USER_PASSWORD="testpassword123"

# Test Results Tracking
TESTS_PASSED=0
TESTS_FAILED=0

function run_test() {
  local test_name="$1"
  local test_command="$2"
  
  echo -n "🧪 Testing $test_name... "
  if eval "$test_command"; then
    echo "✅ PASS"
    ((TESTS_PASSED++))
  else
    echo "❌ FAIL"
    ((TESTS_FAILED++))
  fi
}

# Test 1: Backend Health Check
run_test("Backend Health Check" \
  "curl -s -f \"$BACKEND_URL/\" > /dev/null")

# Test 2: Frontend Accessibility
run_test("Frontend Accessibility" \
  "curl -s -f \"$FRONTEND_URL/\" > /dev/null")

# Test 3: User Registration
run_test("User Registration" \
  "curl -s -X POST \"$BACKEND_URL/api/users/\" \
    -H \"Content-Type: application/json\" \
    -d '{\"email\":\"'$TEST_USER_EMAIL'\",\"username\":\"testuser\",\"password\":\"'$TEST_USER_PASSWORD'\"}' \
    | grep -q \"\"$TEST_USER_EMAIL\"\"")

# Test 4: User Login
run_test("User Login" \
  "LOGIN_RESPONSE=\$(curl -s -X POST \"$BACKEND_URL/api/token\" \
    -H \"Content-Type: application/x-www-form-urlencoded\" \
    -d \"username='$TEST_USER_EMAIL'&password='$TEST_USER_PASSWORD'\") && \
  echo \"\$LOGIN_RESPONSE\" | grep -q \"access_token\"")

# Test 5: Video Generation Initiation
run_test("Video Generation Initiation" \
  "LOGIN_RESPONSE=\$(curl -s -X POST \"$BACKEND_URL/api/token\" \
    -H \"Content-Type: application/x-www-form-urlencoded\" \
    -d \"username='$TEST_USER_EMAIL'&password='$TEST_USER_PASSWORD'\") && \
  TOKEN=\$(echo \"\$LOGIN_RESPONSE\" | grep -o '\"access_token\":\"[^\"]*\"' | cut -d'\"' -f4) && \
  curl -s -X POST \"$BACKEND_URL/api/videos/generate\" \
    -H \"Authorization: Bearer \$TOKEN\" \
    -H \"Content-Type: application/json\" \
    -d '{\"prompt\":\"'$TEST_PROMPT'\",\"use_approval\":false}' \
    | grep -q \"Video generation started\")")

# Test 6: Video Status Retrieval
run_test("Video Status Retrieval" \
  "LOGIN_RESPONSE=\$(curl -s -X POST \"$BACKEND_URL/api/token\" \
    -H \"Content-Type: application/x-www-form-urlencoded\" \
    -d \"username='$TEST_USER_EMAIL'&password='$TEST_USER_PASSWORD'\") && \
  TOKEN=\$(echo \"\$LOGIN_RESPONSE\" | grep -o '\"access_token\":\"[^\"]*\"' | cut -d'\"' -f4) && \
  VIDEO_ID=\$(curl -s -X POST \"$BACKEND_URL/api/videos/generate\" \
    -H \"Authorization: Bearer \$TOKEN\" \
    -H \"Content-Type: application/json\" \
    -d '{\"prompt\":\"'$TEST_PROMPT'\",\"use_approval\":false}' \
    | grep -o '\"video_id\":[0-9]*' | cut -d':' -f2) && \
  curl -s -X GET \"$BACKEND_URL/api/videos/\$VIDEO_ID\" \
    -H \"Authorization: Bearer \$TOKEN\" \
    | grep -q \"\"$TEST_PROMPT\"\")")

# Test 7: Narration Characters Endpoint
run_test("Narration Characters Endpoint" \
  "curl -s \"$BACKEND_URL/api/narration-characters/\" \
    | grep -q \"Narration Character\"")

# Test 8: Caption Templates Endpoint
run_test("Caption Templates Endpoint" \
  "curl -s \"$BACKEND_URL/api/caption-templates/\" \
    | grep -q \"Caption Template\"")

# Summary
echo ""
echo "📊 Test Results Summary"
echo "======================"
echo "✅ Passed: $TESTS_PASSED"
echo "❌ Failed: $TESTS_FAILED"

if [ $TESTS_FAILED -eq 0 ]; then
  echo ""
  echo "🎉 All tests passed! The AI agentic media workflow is functioning correctly."
  exit 0
else
  echo ""
  echo "⚠️  Some tests failed. Please check the services and try again."
  exit 1
fi