#!/bin/bash
set -euo pipefail

echo "════════════════════════════════════════════════════════════"
echo "🚀 CRONOS Code Guard - GitHub Actions Integration"
echo "════════════════════════════════════════════════════════════"
echo "📊 Analysis Mode: ${ANALYSIS_MODE:-STRICT}"
echo "🌐 API Endpoint: ${CRONOS_API_URL:-NOT_SET}"
echo "════════════════════════════════════════════════════════════"

# Validate environment variables
if [ -z "${CRONOS_API_URL:-}" ]; then
  echo "❌ ERROR: CRONOS_API_URL environment variable is not set"
  exit 1
fi

# Remove trailing slash and validate
CRONOS_API_URL="${CRONOS_API_URL%/}"
echo "📡 Using API: ${CRONOS_API_URL}"

# Create report directory
mkdir -p cronos-reports
echo "✓ Created cronos-reports directory"

# Find changed Python files
echo ""
echo "🔍 Detecting changed Python files..."

if [ "${GITHUB_EVENT_NAME:-push}" = "pull_request" ]; then
  BASE_SHA="${GITHUB_BASE_REF:-main}"
  git diff --name-only --diff-filter=AM "origin/$BASE_SHA" HEAD | grep '\.py$' > changed_files.txt || true
else
  if git rev-parse HEAD~1 >/dev/null 2>&1; then
    git diff --name-only --diff-filter=AM HEAD~1 HEAD | grep '\.py$' > changed_files.txt || true
  else
    # First commit - analyze all Python files
    git ls-files '*.py' > changed_files.txt || true
  fi
fi

if [ ! -s changed_files.txt ]; then
  echo "✅ No Python files changed — CRONOS check skipped"
  echo "CRONOS_FINAL_STATUS=PASS" >> "$GITHUB_ENV"
  echo '{"status":"PASS","risk":0,"message":"No Python files changed","findings_count":0}' > cronos-reports/summary.json
  exit 0
fi

echo "📝 Changed files:"
cat changed_files.txt
echo ""

# Initialize counters
OVERALL_STATUS="PASS"
FAIL_COUNT=0
WARN_COUNT=0
PASS_COUNT=0
TOTAL_FILES=0
MAX_RISK=0

# Process each changed file
while IFS= read -r file; do
  TOTAL_FILES=$((TOTAL_FILES + 1))
  
  echo ""
  echo "────────────────────────────────────────────────────────────"
  echo "🔍 Analyzing [$TOTAL_FILES]: $file"
  echo "────────────────────────────────────────────────────────────"
  
  # Extract old version
  if git show HEAD~1:"$file" > /tmp/old_code.py 2>/dev/null; then
    echo "✓ Old version retrieved ($(wc -l < /tmp/old_code.py) lines)"
  else
    echo "⚠️  No previous version — treating as new file"
    echo "" > /tmp/old_code.py
  fi
  
  # Copy new version
  if [ -f "$file" ]; then
    cp "$file" /tmp/new_code.py
    echo "✓ New version retrieved ($(wc -l < /tmp/new_code.py) lines)"
  else
    echo "❌ ERROR: File $file does not exist"
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi
  
  # Create JSON payload using Python (CRITICAL FIX for encoding issues)
  echo "📦 Creating JSON payload..."
  
  python3 << 'PYTHON_PAYLOAD' > /tmp/payload.json
import json
import sys

try:
    # Read files with proper encoding
    with open("/tmp/old_code.py", "r", encoding="utf-8", errors="replace") as f:
        old_code = f.read()
    
    with open("/tmp/new_code.py", "r", encoding="utf-8", errors="replace") as f:
        new_code = f.read()
    
    # Get mode from environment
    import os
    mode = os.environ.get("ANALYSIS_MODE", "STRICT")
    
    # Create payload
    payload = {
        "old_code": old_code,
        "new_code": new_code,
        "mode": mode
    }
    
    # Output valid JSON
    print(json.dumps(payload, ensure_ascii=False))
    sys.exit(0)
    
except Exception as e:
    print(json.dumps({"error": str(e)}), file=sys.stderr)
    sys.exit(1)
PYTHON_PAYLOAD
  
  if [ $? -ne 0 ]; then
    echo "❌ Failed to create JSON payload"
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo '{"status":"FAIL","risk":100,"error":"PAYLOAD_CREATION_FAILED"}' > "cronos-reports/${file//\//_}.json"
    continue
  fi
  
  PAYLOAD_SIZE=$(wc -c < /tmp/payload.json)
  echo "✓ Payload created (${PAYLOAD_SIZE} bytes)"
  
  # Validate payload is valid JSON
  if ! python3 -m json.tool < /tmp/payload.json > /dev/null 2>&1; then
    echo "❌ Invalid JSON payload generated"
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo '{"status":"FAIL","risk":100,"error":"INVALID_PAYLOAD"}' > "cronos-reports/${file//\//_}.json"
    continue
  fi
  
  # Call CRONOS API with improved error handling
  echo "📡 Sending request to ${CRONOS_API_URL}/analyze_ci ..."
  
  HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST "${CRONOS_API_URL}/analyze_ci" \
    -H "Content-Type: application/json; charset=utf-8" \
    -H "Accept: application/json" \
    --data-binary @/tmp/payload.json \
    --max-time 120 \
    --connect-timeout 10 \
    2>&1)
  
  CURL_EXIT=$?
  
  # Extract HTTP code (last line) and body (everything else)
  HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n 1)
  HTTP_BODY=$(echo "$HTTP_RESPONSE" | head -n -1)
  
  echo "$HTTP_BODY" > /tmp/response.txt
  
  echo "✓ Response: HTTP $HTTP_CODE (curl exit: $CURL_EXIT)"
  
  # Check curl errors
  if [ $CURL_EXIT -ne 0 ]; then
    echo "❌ Network Error: Exit code $CURL_EXIT"
    case $CURL_EXIT in
      6) echo "   - Could not resolve host" ;;
      7) echo "   - Failed to connect to host" ;;
      28) echo "   - Operation timeout" ;;
      35) echo "   - SSL connection error" ;;
      *) echo "   - Network error (code: $CURL_EXIT)" ;;
    esac
    
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "{\"status\":\"FAIL\",\"risk\":100,\"error\":\"NETWORK_ERROR\",\"curl_code\":$CURL_EXIT}" > "cronos-reports/${file//\//_}.json"
    continue
  fi
  
  # Check HTTP status
  if [ "$HTTP_CODE" != "200" ]; then
    echo "❌ API Error: HTTP $HTTP_CODE"
    echo "Response body (first 500 chars):"
    head -c 500 /tmp/response.txt
    echo ""
    
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "{\"status\":\"FAIL\",\"risk\":100,\"error\":\"HTTP_${HTTP_CODE}\",\"response\":\"$(head -c 200 /tmp/response.txt | jq -Rs .)\"}" > "cronos-reports/${file//\//_}.json"
    continue
  fi
  
  # Validate JSON response
  if ! python3 -m json.tool < /tmp/response.txt > /dev/null 2>&1; then
    echo "❌ Invalid JSON response from API"
    echo "Response (first 500 chars):"
    head -c 500 /tmp/response.txt
    echo ""
    
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo '{"status":"FAIL","risk":100,"error":"INVALID_JSON_RESPONSE"}' > "cronos-reports/${file//\//_}.json"
    continue
  fi
  
  # Save valid response
  REPORT_FILE="cronos-reports/${file//\//_}.json"
  cp /tmp/response.txt "$REPORT_FILE"
  echo "✓ Report saved: $REPORT_FILE"
  
  # Parse response using Python
  PARSE_RESULT=$(python3 << 'PYTHON_PARSE'
import json
import sys

try:
    with open("/tmp/response.txt", "r") as f:
        data = json.load(f)
    
    status = data.get("status", "UNKNOWN")
    risk = data.get("risk", 0)
    findings = data.get("findings_count", 0)
    summary = data.get("summary", [])
    
    print(f"STATUS={status}")
    print(f"RISK={risk}")
    print(f"FINDINGS={findings}")
    
    if summary and len(summary) > 0:
        print("SUMMARY_START")
        for item in summary[:3]:
            print(f"  • {item}")
        print("SUMMARY_END")
    
    sys.exit(0)
    
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    print("STATUS=UNKNOWN")
    print("RISK=100")
    sys.exit(1)
PYTHON_PARSE
)
  
  if [ $? -ne 0 ]; then
    echo "❌ Failed to parse response"
    echo "$PARSE_RESULT"
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi
  
  # Extract values
  STATUS=$(echo "$PARSE_RESULT" | grep "^STATUS=" | cut -d'=' -f2 || echo "UNKNOWN")
  RISK=$(echo "$PARSE_RESULT" | grep "^RISK=" | cut -d'=' -f2 || echo "0")
  FINDINGS=$(echo "$PARSE_RESULT" | grep "^FINDINGS=" | cut -d'=' -f2 || echo "0")
  
  # Track max risk
  if [ "$RISK" -gt "$MAX_RISK" ]; then
    MAX_RISK=$RISK
  fi
  
  # Display results
  echo ""
  echo "📊 ANALYSIS RESULTS:"
  echo "   Status: $STATUS"
  echo "   Risk Score: $RISK/100"
  echo "   Findings: $FINDINGS"
  
  if echo "$PARSE_RESULT" | grep -q "SUMMARY_START"; then
    echo ""
    echo "   Key Findings:"
    echo "$PARSE_RESULT" | sed -n '/SUMMARY_START/,/SUMMARY_END/p' | grep "•" || true
  fi
  
  # Update counters
  case "$STATUS" in
    "PASS")
      PASS_COUNT=$((PASS_COUNT + 1))
      echo "✅ Analysis PASSED"
      ;;
    "WARN")
      WARN_COUNT=$((WARN_COUNT + 1))
      if [ "$OVERALL_STATUS" = "PASS" ]; then
        OVERALL_STATUS="WARN"
      fi
      echo "⚠️  Analysis WARNING"
      ;;
    "FAIL")
      FAIL_COUNT=$((FAIL_COUNT + 1))
      OVERALL_STATUS="FAIL"
      echo "❌ Analysis FAILED"
      ;;
    *)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      OVERALL_STATUS="FAIL"
      echo "❌ Analysis ERROR - Unknown status: $STATUS"
      ;;
  esac
  
done < changed_files.txt

# Create summary report
cat > cronos-reports/summary.json << EOF
{
  "status": "$OVERALL_STATUS",
  "risk": $MAX_RISK,
  "total_files": $TOTAL_FILES,
  "passed": $PASS_COUNT,
  "warnings": $WARN_COUNT,
  "failed": $FAIL_COUNT,
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

# Final summary
echo ""
echo "════════════════════════════════════════════════════════════"
echo "📊 CRONOS ANALYSIS SUMMARY"
echo "════════════════════════════════════════════════════════════"
echo "📁 Files analyzed: $TOTAL_FILES"
echo "✅ Passed:  $PASS_COUNT"
echo "⚠️  Warning: $WARN_COUNT"
echo "❌ Failed:  $FAIL_COUNT"
echo "🎯 Max Risk: $MAX_RISK/100"
echo "════════════════════════════════════════════════════════════"
echo "🎯 Overall Status: $OVERALL_STATUS"
echo "════════════════════════════════════════════════════════════"

# Set environment variable for outputs
echo "CRONOS_FINAL_STATUS=$OVERALL_STATUS" >> "$GITHUB_ENV"

# Exit based on status and configuration
FAIL_ON_ERROR="${FAIL_ON_ERROR:-true}"

if [ "$OVERALL_STATUS" = "FAIL" ] && [ "$FAIL_ON_ERROR" = "true" ]; then
  echo ""
  echo "❌ CRONOS blocked this change due to high-risk code modifications"
  echo "   Review the reports above for details"
  echo ""
  exit 1
fi

if [ "$OVERALL_STATUS" = "WARN" ]; then
  echo ""
  echo "⚠️  CRONOS detected potential issues - review recommended"
  echo ""
fi

if [ "$OVERALL_STATUS" = "PASS" ]; then
  echo ""
  echo "✅ CRONOS analysis passed - code changes are safe"
  echo ""
fi

exit 0
