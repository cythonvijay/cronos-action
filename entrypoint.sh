#!/bin/bash
set -euo pipefail

echo "════════════════════════════════════════════════════════════"
echo "🚀 CRONOS Code Guard - GitHub Actions Integration"
echo "════════════════════════════════════════════════════════════"
echo "📊 Analysis Mode: $ANALYSIS_MODE"
echo "🌐 API Endpoint: $CRONOS_API_URL"
echo "════════════════════════════════════════════════════════════"

# Create report directory
mkdir -p cronos-reports

# Find changed Python files
echo "🔍 Detecting changed Python files..."
git diff --name-only --diff-filter=AM HEAD~1 HEAD | grep '\.py$' > changed_files.txt || true

# Check if any Python files changed
if [ ! -s changed_files.txt ]; then
  echo "✅ No Python files changed — CRONOS check skipped"
  echo "CRONOS_FINAL_STATUS=PASS" >> "$GITHUB_ENV"
  exit 0
fi

echo "📝 Changed files:"
cat changed_files.txt

# Initialize overall status
OVERALL_STATUS="PASS"
FAIL_COUNT=0
WARN_COUNT=0
PASS_COUNT=0

# Process each changed file
while IFS= read -r file; do
  echo ""
  echo "────────────────────────────────────────────────────────────"
  echo "🔍 Analyzing: $file"
  echo "────────────────────────────────────────────────────────────"
  
  # Extract old version (handle first commit case)
  if git show HEAD~1:"$file" > /tmp/old_code.py 2>/dev/null; then
    echo "✓ Old version retrieved"
  else
    echo "⚠️ No previous version (first commit) — using empty baseline"
    echo "" > /tmp/old_code.py
  fi
  
  # Copy new version
  cp "$file" /tmp/new_code.py
  echo "✓ New version retrieved"
  
  # Create JSON payload using Python
  python3 <<EOF > /tmp/payload.json
import json

with open("/tmp/old_code.py", "r") as f:
    old_code = f.read()

with open("/tmp/new_code.py", "r") as f:
    new_code = f.read()

payload = {
    "old_code": old_code,
    "new_code": new_code,
    "mode": "$ANALYSIS_MODE"
}

print(json.dumps(payload, indent=2))
EOF
  
  echo "✓ Payload created"
  
  # Call CRONOS API
  echo "📡 Sending request to CRONOS API..."
  HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/response.json \
    -X POST "${CRONOS_API_URL}/analyze_ci" \
    -H "Content-Type: application/json" \
    --data-binary @/tmp/payload.json \
    --max-time 120)
  
  echo "✓ API Response (HTTP $HTTP_CODE)"
  
  # Check HTTP status
  if [ "$HTTP_CODE" -ne 200 ]; then
    echo "❌ API Error: HTTP $HTTP_CODE"
    cat /tmp/response.json
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi
  
  # Parse response
  RESPONSE=$(cat /tmp/response.json)
  
  # Save report
  REPORT_FILE="cronos-reports/${file//\//_}.json"
  echo "$RESPONSE" > "$REPORT_FILE"
  echo "✓ Report saved: $REPORT_FILE"
  
  # Extract analysis results using Python
  ANALYSIS=$(python3 <<EOF
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
    
    if summary:
        print("SUMMARY_START")
        for item in summary[:3]:  # Top 3 findings
            print(f"  • {item}")
        print("SUMMARY_END")
    
except Exception as e:
    print(f"ERROR=Failed to parse response: {e}")
    print("STATUS=UNKNOWN")
    
EOF
)
  
  # Parse analysis output
  STATUS=$(echo "$ANALYSIS" | grep "^STATUS=" | cut -d'=' -f2)
  RISK=$(echo "$ANALYSIS" | grep "^RISK=" | cut -d'=' -f2)
  FINDINGS=$(echo "$ANALYSIS" | grep "^FINDINGS=" | cut -d'=' -f2)
  
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
    echo "$ANALYSIS" | sed -n '/SUMMARY_START/,/SUMMARY_END/p' | grep "•"
  fi
  
  # Update counters
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
echo "✅ Passed:  $PASS_COUNT file(s)"
echo "⚠️ Warning: $WARN_COUNT file(s)"
echo "❌ Failed:  $FAIL_COUNT file(s)"
echo "════════════════════════════════════════════════════════════"
echo "🎯 Overall Status: $OVERALL_STATUS"
echo "════════════════════════════════════════════════════════════"

# Set GitHub environment variable
echo "CRONOS_FINAL_STATUS=$OVERALL_STATUS" >> "$GITHUB_ENV"

# Exit with appropriate code
if [ "$OVERALL_STATUS" == "FAIL" ]; then
  echo ""
  echo "❌ CRONOS blocked this change due to high-risk code modifications"
  echo "📁 Review detailed reports in cronos-reports/ directory"
  echo ""
  exit 1
fi

echo ""
echo "✅ CRONOS analysis passed - safe to merge"
echo ""
exit 0
