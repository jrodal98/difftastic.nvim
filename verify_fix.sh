#!/bin/bash
# Verification script for the Lua stack overflow fix

echo "========================================="
echo "Lua Stack Overflow Fix - Verification"
echo "========================================="
echo

# Check if in fbsource
if [ ! -d ~/fbsource ]; then
    echo "❌ Error: ~/fbsource not found"
    exit 1
fi

echo "✓ Found fbsource"

# Check the problematic file
PROBLEM_FILE="www/flib/__generated__/GraphQLHackClientMeerkatStep/single_source/IGStoriesViewerMutation/GraphQLStoriesViewerMutationIGMutation.php"
cd ~/fbsource

if [ ! -f "$PROBLEM_FILE" ]; then
    echo "❌ Error: Problem file not found: $PROBLEM_FILE"
    exit 1
fi

LINE_COUNT=$(wc -l < "$PROBLEM_FILE")
echo "✓ Found problematic file: $LINE_COUNT lines"

# Check if it has @generated marker
if head -30 "$PROBLEM_FILE" | grep -q "@generated"; then
    echo "✓ File has @generated marker"
else
    echo "❌ Error: File missing @generated marker"
    exit 1
fi

# Check if file is in sl status
if sl status | grep -q "$PROBLEM_FILE"; then
    echo "✓ File is modified (in sl status)"
else
    echo "⚠ Warning: File not in sl status (not modified)"
    echo "  This test requires the file to be modified"
fi

echo
echo "========================================="
echo "Manual Verification Steps:"
echo "========================================="
echo
echo "1. cd ~/fbsource"
echo "2. Open Neovim: nvim"
echo "3. Run: :Difft"
echo
echo "Expected behavior (BEFORE fix):"
echo "  ❌ Lua stack overflow error"
echo
echo "Expected behavior (AFTER fix):"
echo "  ✓ Shows: 'Skipping @generated file: ...'"
echo "  ✓ Shows diffs for other 10 files"
echo "  ✓ No crash"
echo
echo "If you see the 'Skipping @generated file' message,"
echo "the fix is working correctly!"
echo
