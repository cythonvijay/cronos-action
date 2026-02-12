#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# CRONOS GitHub Action - Entrypoint Script
# ═══════════════════════════════════════════════════════════════

# Get inputs from environment (set by GitHub Actions)
API_URL="${INPUT_API_URL%/}"
MODE="${INPUT_MODE:-STRICT}"
REPORT_DIR="cronos-reports"

echo "════════════════════════════════════════════════════════════════"
echo "🚀 CRONOS Analysis Starting"
echo "════════════════════════════════════════════════════════════════"
echo "📡 API URL: $API_URL"
echo "🎯 Mode: $MODE"
echo "📂 Working Directory: $(pwd)"
echo "════════════════════════════════════════════════════════════════"

# Create report directory
mkdir -p "$REPORT_DIR"

# Test API connectivity
echo ""
echo "🔌 Testing API connectivity..."
if ! curl -sf --max-time 10 "$API_URL/" > /dev/null 2>&1; then
    echo "❌ ERROR: Cannot reach API at $API_URL"
    echo ""
    echo "Troubleshooting steps:"
    echo "  1. Verify API is running (check your Render dashboard)"
    echo "  2. Check CRONOS_API_URL secret in GitHub repository settings"
    echo "  3. Ensure no firewall blocking the connection"
    echo ""
    exit 1
fi
echo "✅ API is reachable"

# Detect changed Python files
echo ""
echo "📋 Detecting changed Python files..."

FILES=""
if git rev-parse HEAD~1 >/dev/null 2>&1; then
    # Normal case: compare with previous commit
    FILES=$(git diff --name-only HEAD~1 HEAD | grep '\.py$' || true)
    echo "Comparing with HEAD~1"
else
    # First commit: analyze all Python files
    FILES=$(git ls-files '*.py' 2>/dev/null || true)
    echo "First commit detected - analyzing all Python files"
fi

if [ -z "$FILES" ]; then
    echo "✅ No Python files changed - skipping analysis"
    exit 0
fi

echo "Found files to analyze:"
echo "$FILES" | sed 's/^/  • /'
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
    echo "📄 File $TOTAL_COUNT: $file"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Check if file exists
    if [ ! -f "$file" ]; then
        echo "⚠️  File was deleted - skipping"
        continue
    fi
    
    # Get old version
    OLD_CODE=""
    if git rev-parse HEAD~1 >/dev/null 2>&1; then
        if git cat-file -e HEAD~1:"$file" 2>/dev/null; then
            OLD_CODE=$(git show HEAD~1:"$file" 2>/dev/null || echo "")
            echo "Old version: $(echo "$OLD_CODE" | wc -l) lines"
        else
            echo "Old version: New file"
        fi
    else
        echo "Old version: First commit"
    fi
    
    # Get new version
    NEW_CODE=$(cat "$file")
    echo "New version: $(echo "$NEW_CODE" | wc -l) lines"
    
    # Create JSON payload
    echo "Building API request..."
    PAYLOAD=$(jq -n \
        --arg old "$OLD_CODE" \
        --arg new "$NEW_CODE" \
        --arg mode "$MODE" \
        '{
            old_code: $old,
            new_code: $new,
            mode: $mode
        }')
    
    # Call API
    RESPONSE_FILE="/tmp/cronos_response_${TOTAL_COUNT}.json"
    echo "📡 Calling: $API_URL/analyze_ci"
    
    HTTP_CODE=$(curl -s -w "%{http_code}" \
        -o "$RESPONSE_FILE" \
        -X POST "$API_URL/analyze_ci" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        --max-time 60 \
        -d "$PAYLOAD" 2>/dev/null)
    
    echo "HTTP Status: $HTTP_CODE"
    
    # Validate HTTP response
    if [ "$HTTP_CODE" != "200" ]; then
        echo "❌ API Error: HTTP $HTTP_CODE"
        if [ -f "$RESPONSE_FILE" ]; then
            echo "Response:"
            head -20 "$RESPONSE_FILE"
        fi
        OVERALL_STATUS="FAIL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo '{"status":"FAIL","risk":100,"error":"HTTP_ERROR"}' > "$REPORT_DIR/${file//\//_}.json"
        echo ""
        continue
    fi
    
    # Check response file exists and has content
    if [ ! -s "$RESPONSE_FILE" ]; then
        echo "❌ Empty response from API"
        OVERALL_STATUS="FAIL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo '{"status":"FAIL","risk":100,"error":"EMPTY_RESPONSE"}' > "$REPORT_DIR/${file//\//_}.json"
        echo ""
        continue
    fi
    
    # Validate JSON
    if ! jq empty "$RESPONSE_FILE" 2>/dev/null; then
        echo "❌ Invalid JSON response"
        echo "Response content:"
        head -10 "$RESPONSE_FILE"
        OVERALL_STATUS="FAIL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo '{"status":"FAIL","risk":100,"error":"INVALID_JSON"}' > "$REPORT_DIR/${file//\//_}.json"
        echo ""
        continue
    fi
    
    # Extract results
    STATUS=$(jq -r '.status // "UNKNOWN"' "$RESPONSE_FILE")
    RISK=$(jq -r '.risk // 100' "$RESPONSE_FILE")
    FINDINGS=$(jq -r '.findings_count // 0' "$RESPONSE_FILE")
    
    # Save report
    cp "$RESPONSE_FILE" "$REPORT_DIR/${file//\//_}.json"
    
    # Display results
    echo ""
    echo "Results:"
    echo "  Status: $STATUS"
    echo "  Risk: $RISK/100"
    echo "  Findings: $FINDINGS"
    
    # Show summary
    if [ "$FINDINGS" -gt 0 ]; then
        echo "  Summary:"
        jq -r '.summary[]?' "$RESPONSE_FILE" 2>/dev/null | head -3 | sed 's/^/    • /'
    fi
    
    # Update counters
    case "$STATUS" in
        PASS)
            PASS_COUNT=$((PASS_COUNT + 1))
            echo "  ✅ PASS"
            ;;
        WARN)
            WARN_COUNT=$((WARN_COUNT + 1))
            echo "  ⚠️  WARN"
            ;;
        FAIL)
            FAIL_COUNT=$((FAIL_COUNT + 1))
            OVERALL_STATUS="FAIL"
            echo "  ❌ FAIL"
            ;;
        *)
            FAIL_COUNT=$((FAIL_COUNT + 1))
            OVERALL_STATUS="FAIL"
            echo "  ❌ UNKNOWN"
            ;;
    esac
    echo ""
done

# Final summary
echo "════════════════════════════════════════════════════════════════"
echo "📊 Analysis Complete"
echo "════════════════════════════════════════════════════════════════"
echo "Total files: $TOTAL_COUNT"
echo "✅ Passed: $PASS_COUNT"
echo "⚠️  Warnings: $WARN_COUNT"
echo "❌ Failed: $FAIL_COUNT"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Exit with status
if [ "$OVERALL_STATUS" == "FAIL" ]; then
    echo "🚫 BUILD BLOCKED"
    echo "Review reports in cronos-reports/ artifact"
    exit 1
else
    echo "✅ BUILD APPROVED"
    exit 0
fi
