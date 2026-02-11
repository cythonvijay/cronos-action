#!/bin/bash
set -euo pipefail

echo "🚀 Running CRONOS analysis in $ANALYSIS_MODE mode"
echo "🌐 API: $CRONOS_API_URL"

mkdir -p cronos-reports

git diff --name-only --diff-filter=AM HEAD~1 HEAD | grep '\.py$' > changed_files.txt || true

if [ ! -s changed_files.txt ]; then
  echo "✅ No Python files changed — skipping CRONOS."
  exit 0
fi

OVERALL_STATUS="PASS"

while IFS= read -r file; do
  echo "🔍 Analyzing: $file"

  git show HEAD~1:"$file" > /tmp/old_code.py 2>/dev/null || echo "" > /tmp/old_code.py
  cp "$file" /tmp/new_code.py

  python3 <<EOF > /tmp/payload.json
import json
payload = {
  "old_code": open("/tmp/old_code.py").read(),
  "new_code": open("/tmp/new_code.py").read(),
  "mode": "$ANALYSIS_MODE"
}
print(json.dumps(payload))
EOF

  RESPONSE=$(curl -s -X POST "${CRONOS_API_URL}/analyze_ci" \
    -H "Content-Type: application/json" \
    --data-binary @/tmp/payload.json)

  echo "Raw response from Render:"
  echo "$RESPONSE"

  echo "$RESPONSE" > "cronos-reports/${file//\//_}.json"

  if [ -z "$RESPONSE" ]; then
    echo "⚠️ Empty response from API"
    OVERALL_STATUS="FAIL"
    continue
  fi

  STATUS=$(echo "$RESPONSE" | python3 - <<EOF
import json, sys
try:
    print(json.loads(sys.stdin.read()).get("status","UNKNOWN"))
except Exception:
    print("INVALID_JSON")
EOF
)

  echo "➡️ Status for $file = $STATUS"

  if [ "$STATUS" == "FAIL" ]; then
    OVERALL_STATUS="FAIL"
  fi

done < changed_files.txt

echo "CRONOS_FINAL_STATUS=$OVERALL_STATUS" >> $GITHUB_ENV

if [ "$OVERALL_STATUS" == "FAIL" ]; then
  echo "❌ CRONOS blocked this change"
  exit 1
fi

echo "✅ CRONOS passed"
