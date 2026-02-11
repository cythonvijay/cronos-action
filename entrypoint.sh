#!/usr/bin/env bash
set -euo pipefail

API_URL="$1"
REPORT_DIR="cronos-reports"
mkdir -p "$REPORT_DIR"

echo "🚀 CRONOS Analysis Starting..."
echo "API: $API_URL"

# Get changed files in this PR/commit
FILES=$(git diff --name-only HEAD~1 HEAD || true)

if [ -z "$FILES" ]; then
  echo "✅ No code changes detected — skipping analysis."
  exit 0
fi

OVERALL_STATUS="PASS"
FAIL_COUNT=0

for file in $FILES; do
  if [[ ! "$file" =~ \.py$ ]]; then
    echo "⏭️ Skipping non-Python file: $file"
    continue
  fi

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

  echo "📡 Sending to CRONOS..."

  HTTP_STATUS=$(curl -s -w "%{http_code}" \
    -o /tmp/response.txt \
    -X POST "$API_URL/analyze_ci" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")

  echo "HTTP Status: $HTTP_STATUS"

  # 🚨 Critical safety check — prevents crashes
  if [ ! -s /tmp/response.txt ]; then
    echo "❌ EMPTY RESPONSE FROM API"
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo '{"status":"FAIL","risk":100,"error":"EMPTY_API_RESPONSE"}' \
      > "$REPORT_DIR/${file//\//_}.json"
    continue
  fi

  cat /tmp/response.txt | jq '.' > "$REPORT_DIR/${file//\//_}.json"

  RISK=$(jq -r '.risk' /tmp/response.txt)
  STATUS=$(jq -r '.status' /tmp/response.txt)

  echo "➡️ Result: status=$STATUS, risk=$RISK"

  if [[ "$STATUS" == "FAIL" ]]; then
    OVERALL_STATUS="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done

echo "📁 Reports saved in: $REPORT_DIR"

if [[ "$OVERALL_STATUS" == "FAIL" ]]; then
  echo "🚫 CRONOS BLOCKED MERGE — $FAIL_COUNT file(s) failed"
  exit 1
fi

echo "✅ CRONOS PASS — safe to merge"
exit 0
