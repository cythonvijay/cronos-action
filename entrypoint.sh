#!/bin/bash
set -euo pipefail

echo "🚀 Running CRONOS analysis in $ANALYSIS_MODE mode"

mkdir -p cronos-reports

# ---------- Detect changed Python files ----------
if [[ "${GITHUB_EVENT_NAME}" == "pull_request" ]]; then
  BASE_SHA="${GITHUB_BASE_REF:-$(git merge-base HEAD origin/main)}"
  git diff --name-only --diff-filter=AM "$BASE_SHA" HEAD | grep '\.py$' > changed_files.txt || true
else
  git diff --name-only --diff-filter=AM HEAD~1 HEAD | grep '\.py$' > changed_files.txt || true
fi

if [ ! -s changed_files.txt ]; then
  echo "✅ No Python files changed — skipping CRONOS."
  exit 0
fi

OVERALL_STATUS="PASS"

while IFS= read -r file; do
  echo "🔍 Analyzing: $file"

  # Get old version safely (empty if new file)
  git show HEAD~1:"$file" > /tmp/old_code.py 2>/dev/null || echo "" > /tmp/old_code.py
  cp "$file" /tmp/new_code.py

  # ---------- Build clean JSON payload ----------
  python3 <<EOF > /tmp/payload.json
import json

payload = {
    "old_code": open("/tmp/old_code.py").read(),
    "new_code": open("/tmp/new_code.py").read(),
    "mode": "$ANALYSIS_MODE"
}

print(json.dumps(payload))
EOF

  # ---------- Call your Render API ----------
  RESPONSE=$(curl -s -X POST "${CRONOS_API_URL}/analyze_ci" \
    -H "Content-Type: application/json" \
    --data-binary @/tmp/payload.json)

  echo "$RESPONSE" > "cronos-reports/${file//\//_}.json"

  STATUS=$(echo "$RESPONSE" | python3 - <<EOF
import json, sys
print(json.loads(sys.stdin.read()).get("status","UNKNOWN"))
EOF
)

  echo "➡️ Status for $file = $STATUS"

  if [ "$STATUS" == "FAIL" ]; then
    OVERALL_STATUS="FAIL"
  fi

done < changed_files.txt

echo "CRONOS_FINAL_STATUS=$OVERALL_STATUS" >> $GITHUB_ENV

if [ "$OVERALL_STATUS" == "FAIL" ]; then
  echo "❌ CRONOS blocked this change — high risk detected."
  exit 1
fi

echo "✅ CRONOS passed — safe to merge."
