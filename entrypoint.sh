#!/usr/bin/env bash
set -euo pipefail

API_URL="${1%/}"
REPORT_DIR="cronos-reports"
mkdir -p "$REPORT_DIR"

echo "🚀 CRONOS starting — API: $API_URL"

# Get only changed python files
FILES=$(git diff --name-only HEAD~1 HEAD | grep '\.py$' || true)

if [ -z "$FILES" ]; then
  echo "✅ No Python changes — skipping."
  exit 0
fi

OVERALL_STATUS="PASS"
FAIL_COUNT=0

for file in $FILES; do
  echo "🔍 Analyzing: $file"

  OLD_CODE=$(git show HEAD~1:"$file" 2>/dev/null || echo "")
  NEW_CODE=$(cat "$file")

  PAYLOAD=$(jq -n \
    --arg old "$OLD_CODE" \
    --arg new "$NEW_CODE" \
    '{
      old_code: $old,
      new_code: $new,
      mode: "STRICT"
    }')

  echo "📡 Calling $API_URL/analyze_ci"

  HTTP_STATUS=$(curl -s -w "%{http_code}" \
    -o /tmp/raw_response.txt \
    -X POST "$API_URL/analyze_ci" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")

  echo "HTTP: $HTTP_STATUS"

  # ---- HARD SAFETY CHECKS ----
  if [ ! -s /tmp/raw_response.txt ]; then
    echo "❌ EMPTY RESPONSE"
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo '{"status":"FAIL","risk":100,"error":"EMPTY_API_RESPONSE"}' \
      > "$REPORT_DIR/${file//\//_}.json"
    continue
  fi

  if ! jq -e . /tmp/raw_response.txt >/dev/null 2>&1; then
    echo "❌ INVALID JSON RESPONSE"
    cat /tmp/raw_response.txt
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo '{"status":"FAIL","risk":100,"error":"INVALID_JSON_RESPONSE"}' \
      > "$REPORT_DIR/${file//\//_}.json"
    continue
  fi

  # Save valid response
  jq '.' /tmp/raw_response.txt > "$REPORT_DIR/${file//\//_}.json"

  STATUS=$(jq -r '.status' /tmp/raw_response.txt)
  RISK=$(jq -r '.risk' /tmp/raw_response.txt)

  echo "➡️ status=$STATUS, risk=$RISK"

  if [[ "$STATUS" == "FAIL" ]]; then
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done

if [[ "$OVERALL_STATUS" == "FAIL" ]]; then
  echo "🚫 BLOCKED — $FAIL_COUNT file(s) failed"
  exit 1
fi

echo "✅ PASS"
exit 0
