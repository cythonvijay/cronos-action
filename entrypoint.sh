#!/bin/bash
set -e

echo "🚀 Running CRONOS analysis in $ANALYSIS_MODE mode"

mkdir -p cronos-reports

# Detect changed python files
git diff --name-only --diff-filter=AM HEAD~1 HEAD | grep '\.py$' > changed_files.txt || true

if [ ! -s changed_files.txt ]; then
  echo "✅ No Python files changed — skipping CRONOS."
  exit 0
fi

OVERALL_STATUS="PASS"

while IFS= read -r file; do
  echo "Analyzing: $file"

  git show HEAD~1:"$file" > /tmp/old_code.py 2>/dev/null || echo "" > /tmp/old_code.py
  cp "$file" /tmp/new_code.py

  cat <<EOF > /tmp/payload.json
{
  "old_code": $(python3 - << 'EOF2'
import json
print(json.dumps(open('/tmp/old_code.py').read()))
EOF2
),
  "new_code": $(python3 - << 'EOF2'
import json
print(json.dumps(open('/tmp/new_code.py').read()))
EOF2
),
  "mode": "$ANALYSIS_MODE"
}
EOF

  RESPONSE=$(curl -s -X POST "${CRONOS_API_URL}/analyze_ci" \
    -H "Content-Type: application/json" \
    --data-binary @/tmp/payload.json)

  STATUS=$(echo "$RESPONSE" | python3 - << 'EOF'
import json, sys
print(json.loads(sys.stdin.read()).get("status", "UNKNOWN"))
EOF
)

  echo "$RESPONSE" > "cronos-reports/${file//\//_}.json"

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
