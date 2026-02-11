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
  echo "Please set the GitHub secret CRONOS_API_URL"
  exit 1
fi

# Remove trailing slash from API URL if present
CRONOS_API_URL="${CRONOS_API_URL%/}"

# Create report directory (CRITICAL - must exist before upload step)
mkdir -p cronos-reports
echo "✓ Created cronos-reports directory"

# Test API connectivity
echo ""
echo "🔍 Testing API connectivity..."
if ! curl -s --max-time 10 "${CRONOS_API_URL}/" > /dev/null 2>&1; then
  echo "⚠️ WARNING: Could not reach API at ${CRONOS_API_URL}"
  echo "Attempting to continue anyway..."
fi

# Find changed Python files
echo ""
echo "🔍 Detecting changed Python files..."

# Handle different scenarios
if [ "${GITHUB_EVENT_NAME:-push}" = "pull_request" ]; then
  # For PRs, compare base to head
  BASE_SHA="${GITHUB_BASE_REF:-main}"
  echo "📌 Comparing against base: $BASE_SHA"
  git diff --name-only --diff-filter=AM "origin/$BASE_SHA" HEAD | grep '\.py$' > changed_files.txt || true
else
  # For pushes, compare with previous commit
  if git rev-parse HEAD~1 >/dev/null 2>&1; then
    echo "📌 Comparing HEAD~1 to HEAD"
    git diff --name-only --diff-filter=AM HEAD~1 HEAD | grep '\.py$' > changed_files.txt || true
  else
    echo "📌 First commit detected - analyzing all Python files"
    git ls-files '*.py' > changed_files.txt || true
  fi
fi

# Check if any Python files changed
if [ ! -s changed_files.txt ]; then
  echo "✅ No Python files changed — CRONOS check skipped"
  echo "CRONOS_FINAL_STATUS=PASS" >> "$GITHUB_ENV"
  
  # Create a dummy report so artifact upload doesn't fail
  echo '{"status":"PASS","message":"No Python files changed"}' > cronos-reports/no_changes.json
  
  exit 0
fi

echo "📝 Changed files:"
cat changed_files.txt
echo ""

# Initialize overall status
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
  
  # Extract old version (handle first commit and new files)
  if git show HEAD~1:"$file" > /tmp/old_code.py 2>/dev/null; then
    echo "✓ Old version retrieved ($(wc -l < /tmp/old_code.py) lines)"
  else
    echo "⚠️ No previous version (new file or first commit) — using empty baseline"
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
  
  # Create JSON payload using Python (safer than heredoc)
  python3 > /tmp/payload.json <<'PYTHON_SCRIPT'
import json
import sys

try:
    with open("/tmp/old_code.py", "r", encoding="utf-8", errors="ignore") as f:
        old_code = f.read()
    
    with open("/tmp/new_code.py", "r", encoding="utf-8", errors="ignore") as f:
        new_code = f.read()
    
    payload = {
        "old_code": old_code,
        "new_code": new_code,
        "mode": "$ANALYSIS_MODE"
    }
    
    print(json.dumps(payload))
    sys.exit(0)
    
except Exception as e:
    print(f"ERROR: Failed to create payload: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_SCRIPT

  # Replace $ANALYSIS_MODE in the Python script
  sed -i "s/\$ANALYSIS_MODE/${ANALYSIS_MODE:-STRICT}/g" /tmp/payload.json
  
  if [ ! -s /tmp/payload.json ]; then
    echo "❌ Failed to create payload"
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi
  
  echo "✓ Payload created ($(wc -c < /tmp/payload.json) bytes)"
  
  # Call CRONOS API with detailed error handling
  echo "📡 Sending request to ${CRONOS_API_URL}/analyze_ci ..."
  
  # Use curl with separate output and HTTP code
  HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/response.txt \
    -X POST "${CRONOS_API_URL}/analyze_ci" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    --data-binary @/tmp/payload.json \
    --max-time 120 \
    --connect-timeout 10)
  
  CURL_EXIT_CODE=$?
  
  echo "✓ API Response: HTTP $HTTP_CODE (curl exit: $CURL_EXIT_CODE)"
  
  # Check for curl errors
  if [ $CURL_EXIT_CODE -ne 0 ]; then
    echo "❌ Curl Error: Exit code $CURL_EXIT_CODE"
    echo "   This usually means:"
    case $CURL_EXIT_CODE in
      6) echo "   - DNS resolution failed (invalid API URL)" ;;
      7) echo "   - Could not connect to server (is API running?)" ;;
      28) echo "   - Operation timeout (API too slow or down)" ;;
      *) echo "   - Network or connection error" ;;
    esac
    echo ""
    echo "Debug info:"
    echo "  API URL: ${CRONOS_API_URL}/analyze_ci"
    echo "  Please verify your CRONOS_API_URL secret is correct"
    
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    
    # Create error report
    echo '{"status":"FAIL","risk":100,"error":"API_UNREACHABLE"}' > "cronos-reports/${file//\//_}.json"
    
    continue
  fi
  
  # Check HTTP status code
  if [ "$HTTP_CODE" != "200" ]; then
    echo "❌ API Error: HTTP $HTTP_CODE"
    echo ""
    echo "Response body:"
    cat /tmp/response.txt
    echo ""
    
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    
    # Create error report
    echo "{\"status\":\"FAIL\",\"risk\":100,\"error\":\"HTTP_${HTTP_CODE}\"}" > "cronos-reports/${file//\//_}.json"
    
    continue
  fi
  
  # Read and validate response
  RESPONSE=$(cat /tmp/response.txt)
  
  # Check if response is empty
  if [ -z "$RESPONSE" ]; then
    echo "❌ Empty response from API"
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    
    # Create error report
    echo '{"status":"FAIL","risk":100,"error":"EMPTY_RESPONSE"}' > "cronos-reports/${file//\//_}.json"
    
    continue
  fi
  
  # Validate JSON before parsing
  if ! echo "$RESPONSE" | python3 -m json.tool > /dev/null 2>&1; then
    echo "❌ Invalid JSON response from API"
    echo ""
    echo "Response (first 500 chars):"
    echo "$RESPONSE" | head -c 500
    echo ""
    
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    
    # Create error report
    echo '{"status":"FAIL","risk":100,"error":"INVALID_JSON"}' > "cronos-reports/${file//\//_}.json"
    
    continue
  fi
  
  # Save report (valid JSON)
  REPORT_FILE="cronos-reports/${file//\//_}.json"
  echo "$RESPONSE" > "$REPORT_FILE"
  echo "✓ Report saved: $REPORT_FILE"
  
  # Parse analysis results using Python
  ANALYSIS=$(python3 <<PYTHON_PARSE
import json
import sys

try:
    data = json.loads('''$RESPONSE''')
    
    status = data.get("status", "UNKNOWN")
    risk = data.get("risk", 0)
    findings_count = data.get("findings_count", 0)
    summary = data.get("summary", [])
    
    print(f"STATUS={status}")
    print(f"RISK={risk}")
    print(f"FINDINGS={findings_count}")
    
    if summary and len(summary) > 0:
        print("SUMMARY_START")
        for item in summary[:3]:
            print(f"  • {item}")
        print("SUMMARY_END")
    
except Exception as e:
    print(f"ERROR=Failed to parse response: {e}", file=sys.stderr)
    print("STATUS=UNKNOWN")
    sys.exit(1)
PYTHON_PARSE
)
  
  PARSE_EXIT_CODE=$?
  
  if [ $PARSE_EXIT_CODE -ne 0 ]; then
    echo "❌ Failed to parse analysis results"
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi
  
  # Extract values from analysis output
  STATUS=$(echo "$ANALYSIS" | grep "^STATUS=" | cut -d'=' -f2 || echo "UNKNOWN")
  RISK=$(echo "$ANALYSIS" | grep "^RISK=" | cut -d'=' -f2 || echo "0")
  FINDINGS=$(echo "$ANALYSIS" | grep "^FINDINGS=" | cut -d'=' -f2 || echo "0")
  
  # Display results
  echo ""
  echo "📊 ANALYSIS RESULTS:"
  echo "   Status: $STATUS"
  echo "   Risk Score: $RISK/100"
  echo "   Findings: $FINDINGS"
  
  # Show summary if present
  if echo "$ANALYSIS" | grep -q "SUMMARY_START"; then
    echo ""
    echo "   Key Findings:"
    echo "$ANALYSIS" | sed -n '/SUMMARY_START/,/SUMMARY_END/p' | grep "•" || true
  fi
  
  # Update counters based on status
  case "$STATUS" in
    "PASS")
      PASS_COUNT=$((PASS_COUNT + 1))
      echo "✅ Analysis PASSED"
      ;;
    "WARN")
      WARN_COUNT=$((WARN_COUNT + 1))
      echo "⚠️ Analysis WARNING - Review recommended"
      ;;
    "FAIL")
      FAIL_COUNT=$((FAIL_COUNT + 1))
      OVERALL_STATUS="FAIL"
      echo "❌ Analysis FAILED - High risk changes detected"
      ;;
    *)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      OVERALL_STATUS="FAIL"
      echo "❌ Analysis ERROR - Unknown status: $STATUS"
      ;;
  esac
  
done < changed_files.txt

# Final summary
echo ""
echo "════════════════════════════════════════════════════════════"
echo "📊 CRONOS ANALYSIS SUMMARY"
echo "════════════════════════════════════════════════════════════"
echo "📁 Files analyzed: $TOTAL_FILES"
echo "✅ Passed:  $PASS_COUNT file(s)"
echo "⚠️ Warning: $WARN_COUNT file(s)"
echo "❌ Failed:  $FAIL_COUNT file(s)"
echo "════════════════════════════════════════════════════════════"
echo "🎯 Overall Status: $OVERALL_STATUS"
echo "════════════════════════════════════════════════════════════"

# Ensure at least one report exists for artifact upload
if [ ! "$(ls -A cronos-reports 2>/dev/null)" ]; then
  echo '{"status":"ERROR","message":"No reports generated"}' > cronos-reports/error.json
  echo "⚠️ Created placeholder report for artifact upload"
fi

# Set GitHub environment variable
echo "CRONOS_FINAL_STATUS=$OVERALL_STATUS" >> "$GITHUB_ENV"

# Exit with appropriate code
if [ "$OVERALL_STATUS" == "FAIL" ]; then
  echo ""
  echo "❌ CRONOS blocked this change due to high-risk code modifications"
  echo "📁 Review detailed reports in workflow artifacts"
  echo ""
  exit 1
fi

echo ""
echo "✅ CRONOS analysis passed - safe to merge"
echo ""
exit 0
