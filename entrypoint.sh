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

CRONOS_API_URL="${CRONOS_API_URL%/}"
echo "📡 Using API: ${CRONOS_API_URL}"

mkdir -p cronos-reports
echo "✓ Created cronos-reports directory"

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
  echo '{"status":"PASS","risk":0,"message":"No Python files changed","findings_count":0}' > cronos-reports/summary.json
  echo "CRONOS_FINAL_STATUS=PASS" >> "$GITHUB_ENV"
  exit 0
fi

echo "📝 Changed files:"
cat changed_files.txt
echo ""

OVERALL_STATUS="PASS"
FAIL_COUNT=0
WARN_COUNT=0
PASS_COUNT=0
TOTAL_FILES=0
MAX_RISK=0

while IFS= read -r file; do
  TOTAL_FILES=$((TOTAL_FILES + 1))

  echo ""
  echo "────────────────────────────────────────────────────────────"
  echo "🔍 Analyzing [$TOTAL_FILES]: $file"
  echo "────────────────────────────────────────────────────────────"

  if git show HEAD~1:"$file" > /tmp/old_code.py 2>/dev/null; then
    echo "✓ Old version retrieved"
  else
    echo "⚠️ No previous version — treating as new file"
    echo "" > /tmp/old_code.py
  fi

  if [ -f "$file" ]; then
    cp "$file" /tmp/new_code.py
    echo "✓ New version retrieved"
  else
    echo "❌ ERROR: File $file does not exist"
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  echo "📦 Creating JSON payload..."

  python3 << 'EOF' > /tmp/payload.json
import json, os

with open("/tmp/old_code.py", "r", encoding="utf-8", errors="replace") as f:
    old_code = f.read()

with open("/tmp/new_code.py", "r", encoding="utf-8", errors="replace") as f:
    new_code = f.read()

payload = {
    "old_code": old_code,
    "new_code": new_code,
    "mode": os.environ.get("ANALYSIS_MODE", "STRICT")
}

print(json.dumps(payload, ensure_ascii=False))
EOF

  if ! python3 -m json.tool < /tmp/payload.json > /dev/null 2>&1; then
    echo "❌ Invalid payload generated"
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  echo "📡 Sending request to ${CRONOS_API_URL}/analyze_ci ..."

  HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST "${CRONOS_API_URL}/analyze_ci" \
    -H "Content-Type: application/json; charset=utf-8" \
    -H "Accept: application/json" \
    --data-binary @/tmp/payload.json \
    --max-time 120 \
    --connect-timeout 10 \
    2>&1)

  HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n 1)
  HTTP_BODY=$(echo "$HTTP_RESPONSE" | head -n -1)

  echo "$HTTP_BODY" > /tmp/response.txt

  echo "✓ Response: HTTP $HTTP_CODE"

  # ✅ CRITICAL FIX — prevents your JSON crash
  if [ ! -s /tmp/response.txt ]; then
    echo "❌ API returned empty response"
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo '{"status":"FAIL","risk":100,"error":"EMPTY_API_RESPONSE"}' > "cronos-reports/${file//\//_}.json"
    continue
  fi

  if [ "$HTTP_CODE" != "200" ]; then
    echo "❌ API Error: HTTP $HTTP_CODE"
    head -c 500 /tmp/response.txt
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  if ! python3 -m json.tool < /tmp/response.txt > /dev/null 2>&1; then
    echo "❌ Invalid JSON from API"
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  REPORT_FILE="cronos-reports/${file//\//_}.json"
  cp /tmp/response.txt "$REPORT_FILE"
  echo "✓ Report saved: $REPORT_FILE"

  PARSE_RESULT=$(python3 << 'EOF'
import json

with open("/tmp/response.txt") as f:
    data = json.load(f)

print(data.get("status","UNKNOWN"))
print(data.get("risk",0))
EOF
)

  STATUS=$(echo "$PARSE_RESULT" | head -n 1)
  RISK=$(echo "$PARSE_RESULT" | tail -n 1)

  if [ "$RISK" -gt "$MAX_RISK" ]; then
    MAX_RISK=$RISK
  fi

  case "$STATUS" in
    "PASS") PASS_COUNT=$((PASS_COUNT + 1)) ;;
    "WARN") WARN_COUNT=$((WARN_COUNT + 1)); OVERALL_STATUS="WARN" ;;
    "FAIL") FAIL_COUNT=$((FAIL_COUNT + 1)); OVERALL_STATUS="FAIL" ;;
    *) FAIL_COUNT=$((FAIL_COUNT + 1)); OVERALL_STATUS="FAIL" ;;
  esac

done < changed_files.txt

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

echo "════════════════════════════════════════════════════════════"
echo "📊 CRONOS SUMMARY"
echo "Files: $TOTAL_FILES | Passed: $PASS_COUNT | Warn: $WARN_COUNT | Fail: $FAIL_COUNT"
echo "Overall Status: $OVERALL_STATUS"
echo "════════════════════════════════════════════════════════════"

echo "CRONOS_FINAL_STATUS=$OVERALL_STATUS" >> "$GITHUB_ENV"

if [ "$OVERALL_STATUS" = "FAIL" ]; then
  echo "❌ Blocking due to high-risk changes"
  exit 1
fi

exit 0
