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

# Remove trailing slash
CRONOS_API_URL="${CRONOS_API_URL%/}"

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
    git ls-files '*.py' > changed_files.txt || true
  fi
fi

if [ ! -s changed_files.txt ]; then
  echo "✅ No Python files changed — CRONOS check skipped"
  echo "CRONOS_FINAL_STATUS=PASS" >> "$GITHUB_ENV"
  echo '{"status":"PASS","message":"No Python files changed"}' > cronos-reports/no_changes.json
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
    echo "⚠️ No previous version — using empty baseline"
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
  
  # Create JSON payload using a separate Python script (CRITICAL FIX)
  cat > /tmp/create_payload.py <<'PAYLOAD_SCRIPT'
import json
import sys

try:
    # Read files with error handling
    with open("/tmp/old_code.py", "r", encoding="utf-8", errors="replace") as f:
        old_code = f.read()
    
    with open("/tmp/new_code.py", "r", encoding="utf-8", errors="replace") as f:
        new_code = f.read()
    
    # Get mode from environment or use STRICT
    import os
    mode = os.environ.get("ANALYSIS_MODE", "STRICT")
    
    # Create payload
    payload = {
        "old_code": old_code,
        "new_code": new_code,
        "mode": mode
    }
    
    # Write to stdout
    print(json.dumps(payload))
    
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PAYLOAD_SCRIPT
  
  # Run Python script to create payload
  if ! python3 /tmp/create_payload.py > /tmp/payload.json 2>/tmp/payload_error.txt; then
    echo "❌ Failed to create payload:"
    cat /tmp/payload_error.txt
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi
  
  if [ ! -s /tmp/payload.json ]; then
    echo "❌ Payload is empty"
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi
  
  echo "✓ Payload created ($(wc -c < /tmp/payload.json) bytes)"
  
  # Call CRONOS API
  echo "📡 Sending request to ${CRONOS_API_URL}/analyze_ci ..."
  
  HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/response.txt \
    -X POST "${CRONOS_API_URL}/analyze_ci" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    --data-binary @/tmp/payload.json \
    --max-time 120 \
    --connect-timeout 10 2>&1)
  
  CURL_EXIT=$?
  
  echo "✓ Response: HTTP $HTTP_CODE (curl exit: $CURL_EXIT)"
  
  # Check curl errors
  if [ $CURL_EXIT -ne 0 ]; then
    echo "❌ Curl Error: Exit code $CURL_EXIT"
    case $CURL_EXIT in
      6) echo "   - DNS resolution failed" ;;
      7) echo "   - Connection failed" ;;
      28) echo "   - Operation timeout" ;;
      *) echo "   - Network error" ;;
    esac
    echo "   API URL: ${CRONOS_API_URL}/analyze_ci"
    
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo '{"status":"FAIL","risk":100,"error":"API_UNREACHABLE"}' > "cronos-reports/${file//\//_}.json"
    continue
  fi
  
  # Check HTTP status
  if [ "$HTTP_CODE" != "200" ]; then
    echo "❌ API Error: HTTP $HTTP_CODE"
    echo "Response:"
    cat /tmp/response.txt | head -20
    
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "{\"status\":\"FAIL\",\"risk\":100,\"error\":\"HTTP_${HTTP_CODE}\"}" > "cronos-reports/${file//\//_}.json"
    continue
  fi
  
  # Validate JSON response
  if ! python3 -m json.tool < /tmp/response.txt > /dev/null 2>&1; then
    echo "❌ Invalid JSON response"
    echo "Response (first 500 chars):"
    head -c 500 /tmp/response.txt
    echo ""
    
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo '{"status":"FAIL","risk":100,"error":"INVALID_JSON"}' > "cronos-reports/${file//\//_}.json"
    continue
  fi
  
  # Save valid response
  REPORT_FILE="cronos-reports/${file//\//_}.json"
  cp /tmp/response.txt "$REPORT_FILE"
  echo "✓ Report saved: $REPORT_FILE"
  
  # Parse response using Python (separate script for safety)
  cat > /tmp/parse_response.py <<'PARSE_SCRIPT'
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
    
    if summary:
        print("SUMMARY_START")
        for item in summary[:3]:
            print(f"  • {item}")
        print("SUMMARY_END")
    
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    print("STATUS=UNKNOWN")
    sys.exit(1)
PARSE_SCRIPT
  
  if ! ANALYSIS=$(python3 /tmp/parse_response.py 2>&1); then
    echo "❌ Failed to parse response"
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi
  
  # Extract values
  STATUS=$(echo "$ANALYSIS" | grep "^STATUS=" | cut -d'=' -f2 || echo "UNKNOWN")
  RISK=$(echo "$ANALYSIS" | grep "^RISK=" | cut -d'=' -f2 || echo "0")
  FINDINGS=$(echo "$ANALYSIS" | grep "^FINDINGS=" | cut -d'=' -f2 || echo "0")
  
  # Display results
  echo ""
  echo "📊 ANALYSIS RESULTS:"
  echo "   Status: $STATUS"
  echo "   Risk Score: $RISK/100"
  echo "   Findings: $FINDINGS"
  
  if echo "$ANALYSIS" | grep -q "SUMMARY_START"; then
    echo ""
    echo "   Key Findings:"
    echo "$ANALYSIS" | sed -n '/SUMMARY_START/,/SUMMARY_END/p' | grep "•" || true
  fi
  
  # Update counters
  case "$STATUS" in
    "PASS")
      PASS_COUNT=$((PASS_COUNT + 1))
      echo "✅ Analysis PASSED"
      ;;
    "WARN")
      WARN_COUNT=$((WARN_COUNT + 1))
      echo "⚠️ Analysis WARNING"
      ;;
    "FAIL")
      FAIL_COUNT=$((FAIL_COUNT + 1))
      OVERALL_STATUS="FAIL"
      echo "❌ Analysis FAILED"
      ;;
    *)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      OVERALL_STATUS="FAIL"
      echo "❌ Analysis ERROR - Unknown status"
      ;;
  esac
  
done < changed_files.txt

# Final summary
echo ""
echo "════════════════════════════════════════════════════════════"
echo "📊 CRONOS ANALYSIS SUMMARY"
echo "════════════════════════════════════════════════════════════"
echo "📁 Files analyzed: $TOTAL_FILES"
echo "✅ Passed:  $PASS_COUNT"
echo "⚠️ Warning: $WARN_COUNT"
echo "❌ Failed:  $FAIL_COUNT"
echo "════════════════════════════════════════════════════════════"
echo "🎯 Overall Status: $OVERALL_STATUS"
echo "════════════════════════════════════════════════════════════"

# Ensure reports exist
if [ ! "$(ls -A cronos-reports 2>/dev/null)" ]; then
  echo '{"status":"ERROR","message":"No reports generated"}' > cronos-reports/error.json
fi

# Set environment variable
echo "CRONOS_FINAL_STATUS=$OVERALL_STATUS" >> "$GITHUB_ENV"

# Exit
if [ "$OVERALL_STATUS" == "FAIL" ]; then
  echo ""
  echo "❌ CRONOS blocked this change"
  echo ""
  exit 1
fi

echo ""
echo "✅ CRONOS passed"
echo ""
exit 0
