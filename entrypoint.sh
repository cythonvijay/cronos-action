#!/bin/bash
set -euo pipefail

# Get inputs from GitHub Actions environment
API_URL="${INPUT_API_URL%/}"
MODE="${INPUT_MODE:-STRICT}"
REPORT_DIR="cronos-reports"

echo "════════════════════════════════════════════════════════════════"
echo "🚀 CRONOS Analysis Starting"
echo "════════════════════════════════════════════════════════════════"
echo "📡 API URL: $API_URL"
echo "🎯 Mode: $MODE"
echo "📂 Working Directory: $(pwd)"
echo "🔍 Git Status:"
git status --short || echo "Git status unavailable"
echo "════════════════════════════════════════════════════════════════"

# Create report directory
mkdir -p "$REPORT_DIR"

# Test API connectivity first
echo ""
echo "🔌 Testing API connectivity..."
if ! curl -sf --max-time 10 "$API_URL/" > /dev/null; then
    echo "❌ ERROR: Cannot reach API at $API_URL"
    echo "Please verify:"
    echo "  1. API is running and accessible"
    echo "  2. CRONOS_API_URL secret is correct"
    echo "  3. No firewall blocking the connection"
    exit 1
fi
echo "✅ API is reachable"

# Get changed Python files
echo ""
echo "📋 Detecting changed Python files..."

# Try multiple methods to get changed files
if git rev-parse HEAD~1 >/dev/null 2>&1; then
    # Normal case: compare with previous commit
    FILES=$(git diff --name-only HEAD~1 HEAD | grep '\.py$' || true)
    echo "Using diff with HEAD~1"
else
    # First commit case: get all Python files
    FILES=$(git ls-files '*.py' || true)
    echo "First commit detected - analyzing all Python files"
fi

if [ -z "$FILES" ]; then
    echo "✅ No Python files changed - skipping analysis"
    exit 0
fi

echo "Found Python files:"
echo "$FILES" | sed 's/^/  - /'
echo ""

# Initialize counters
OVERALL_STATUS="PASS"
FAIL_COUNT=0
WARN_COUNT=0
PASS_COUNT=0
TOTAL_COUNT=0

# Analyze each file
for file in $FILES; do
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📄 Analyzing: $file"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Check if file exists in current version
    if [ ! -f "$file" ]; then
        echo "⚠️  File deleted - skipping analysis"
        continue
    fi
    
    # Get old version (empty if file is new)
    if git rev-parse HEAD~1 >/dev/null 2>&1 && git cat-file -e HEAD~1:"$file" 2>/dev/null; then
        OLD_CODE=$(git show HEAD~1:"$file" 2>/dev/null || echo "")
        echo "📖 Old version: $(echo "$OLD_CODE" | wc -l) lines"
    else
        OLD_CODE=""
        echo "📖 Old version: New file"
    fi
    
    # Get new version
    NEW_CODE=$(cat "$file")
    echo "📝 New version: $(echo "$NEW_CODE" | wc -l) lines"
    
    # Build JSON payload with proper escaping
    PAYLOAD=$(jq -n \
        --arg old "$OLD_CODE" \
        --arg new "$NEW_CODE" \
        --arg mode "$MODE" \
        '{
            old_code: $old,
            new_code: $new,
            mode: $mode
        }')
    
    # Make API call with detailed debugging
    echo "📡 Calling API endpoint: $API_URL/analyze_ci"
    
    RESPONSE_FILE="/tmp/cronos_response_${TOTAL_COUNT}.json"
    HTTP_CODE=$(curl -s -w "%{http_code}" \
        -o "$RESPONSE_FILE" \
        -X POST "$API_URL/analyze_ci" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        --max-time 30 \
        -d "$PAYLOAD")
    
    echo "📊 HTTP Status: $HTTP_CODE"
    
    # Validate HTTP response
    if [ "$HTTP_CODE" != "200" ]; then
        echo "❌ ERROR: API returned HTTP $HTTP_CODE"
        echo "Response body:"
        cat "$RESPONSE_FILE" || echo "(empty response)"
        OVERALL_STATUS="FAIL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo '{"status":"FAIL","risk":100,"error":"HTTP_ERROR","http_code":'$HTTP_CODE'}' \
            > "$REPORT_DIR/${file//\//_}.json"
        continue
    fi
    
    # Validate response exists
    if [ ! -s "$RESPONSE_FILE" ]; then
        echo "❌ ERROR: Empty API response"
        OVERALL_STATUS="FAIL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo '{"status":"FAIL","risk":100,"error":"EMPTY_RESPONSE"}' \
            > "$REPORT_DIR/${file//\//_}.json"
        continue
    fi
    
    # Validate JSON format
    if ! jq empty "$RESPONSE_FILE" 2>/dev/null; then
        echo "❌ ERROR: Invalid JSON response"
        echo "Response content:"
        cat "$RESPONSE_FILE"
        OVERALL_STATUS="FAIL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo '{"status":"FAIL","risk":100,"error":"INVALID_JSON"}' \
            > "$REPORT_DIR/${file//\//_}.json"
        continue
    fi
    
    # Parse response
    STATUS=$(jq -r '.status // "UNKNOWN"' "$RESPONSE_FILE")
    RISK=$(jq -r '.risk // 100' "$RESPONSE_FILE")
    FINDINGS_COUNT=$(jq -r '.findings_count // 0' "$RESPONSE_FILE")
    
    # Save report
    jq '.' "$RESPONSE_FILE" > "$REPORT_DIR/${file//\//_}.json"
    
    # Display results
    echo ""
    echo "📈 Results:"
    echo "   Status: $STATUS"
    echo "   Risk Score: $RISK/100"
    echo "   Findings: $FINDINGS_COUNT"
    
    # Show summary if available
    if [ "$FINDINGS_COUNT" -gt 0 ]; then
        echo "   Summary:"
        jq -r '.summary[]?' "$RESPONSE_FILE" | sed 's/^/     • /'
    fi
    
    # Update counters
    case "$STATUS" in
        PASS)
            PASS_COUNT=$((PASS_COUNT + 1))
            echo "✅ PASS"
            ;;
        WARN)
            WARN_COUNT=$((WARN_COUNT + 1))
            echo "⚠️  WARN"
            ;;
        FAIL)
            FAIL_COUNT=$((FAIL_COUNT + 1))
            OVERALL_STATUS="FAIL"
            echo "❌ FAIL"
            ;;
        *)
            FAIL_COUNT=$((FAIL_COUNT + 1))
            OVERALL_STATUS="FAIL"
            echo "❌ UNKNOWN STATUS"
            ;;
    esac
    echo ""
done

# Final summary
echo "════════════════════════════════════════════════════════════════"
echo "📊 CRONOS Analysis Complete"
echo "════════════════════════════════════════════════════════════════"
echo "Files Analyzed: $TOTAL_COUNT"
echo "✅ Passed: $PASS_COUNT"
echo "⚠️  Warnings: $WARN_COUNT"
echo "❌ Failed: $FAIL_COUNT"
echo "════════════════════════════════════════════════════════════════"

# Exit with appropriate code
if [ "$OVERALL_STATUS" == "FAIL" ]; then
    echo ""
    echo "🚫 BUILD BLOCKED - $FAIL_COUNT file(s) failed analysis"
    echo "Review the reports in cronos-reports/ for details"
    exit 1
else
    echo ""
    echo "✅ BUILD APPROVED - All checks passed"
    exit 0
fi
