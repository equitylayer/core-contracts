#!/bin/bash
set -eo pipefail

THRESHOLD=85

echo "Running coverage..."
echo ""

forge coverage --no-match-coverage "(test/|script/|Mock|Base|Deploy|ShareholderSchemas)" --ir-minimum --report summary --color always 2>&1 | tee coverage_raw.txt
FORGE_EXIT=${PIPESTATUS[0]}

if [[ $FORGE_EXIT -ne 0 ]]; then
    echo ""
    echo "======================================"
    echo "Status: ❌ COVERAGE FAILED (tests may have failed)"
    echo "======================================"
    rm -f coverage_raw.txt
    exit 1
fi

# Strip ANSI color codes for parsing
sed 's/\x1b\[[0-9;]*m//g' coverage_raw.txt > coverage.txt
rm -f coverage_raw.txt

COVERAGE=$(grep "| Total" coverage.txt | awk -F'|' '{split($4, a, "%"); gsub(/[^0-9.]/, "", a[1]); print a[1]}')

if [[ -z "$COVERAGE" ]] || ! [[ "$COVERAGE" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    echo ""
    echo "======================================"
    echo "Status: ❌ FAILED TO PARSE COVERAGE"
    echo "Check coverage.txt for details"
    echo "======================================"
    exit 1
fi

echo ""
echo "======================================"
echo "Statement Coverage: $COVERAGE%"
echo "Threshold: $THRESHOLD%"

if (( $(echo "$COVERAGE < $THRESHOLD" | bc -l) )); then
    echo "Status: ❌ BELOW THRESHOLD"
    echo "======================================"
    rm -f coverage.txt
    exit 1
fi

echo "Status: ✅ PASSING"
echo "======================================"
rm -f coverage.txt
