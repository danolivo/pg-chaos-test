#!/bin/bash
# Detect core files, assertion failures, and segfaults in PostgreSQL
# test output. Scans log files, regression output, and the filesystem.
#
# Exit code: 0 = clean, 1 = crash evidence found.

SEARCHDIR="${1:-.}"
found=0

echo "=== Checking for core dumps ==="
cores=$(find "$SEARCHDIR" -name 'core' -o -name 'core.*' 2>/dev/null)
if [ -n "$cores" ]; then
    found=1
    echo "FOUND core files:"
    echo "$cores"
    echo
else
    echo "No core files found."
fi

echo "=== Checking for TRAP/assertion failures ==="
# PostgreSQL uses TRAP for failed assertions, printed to stderr / log files.
trap_matches=$(find "$SEARCHDIR" \( -name '*.log' -o -name 'postmaster.log' \
    -o -name 'regression.out' -o -name 'pg_upgrade_output.d' \) \
    -exec grep -l 'TRAP:' {} \; 2>/dev/null)
if [ -n "$trap_matches" ]; then
    found=1
    echo "FOUND assertion failures (TRAP) in:"
    for f in $trap_matches; do
        echo "--- $f ---"
        grep -n 'TRAP:' "$f" | head -20
        echo
    done
else
    echo "No assertion failures found."
fi

echo "=== Checking for segfaults / signals ==="
# Look for server crash evidence in log files.
crash_patterns='segfault\|SIGSEGV\|SIGBUS\|SIGABRT\|SIGILL\|server process .* was terminated by signal\|terminating any other active server processes'
crash_matches=$(find "$SEARCHDIR" \( -name '*.log' -o -name 'postmaster.log' \
    -o -name 'regression.out' \) \
    -exec grep -li "$crash_patterns" {} \; 2>/dev/null)
if [ -n "$crash_matches" ]; then
    found=1
    echo "FOUND crash signals in:"
    for f in $crash_matches; do
        echo "--- $f ---"
        grep -n "$crash_patterns" "$f" | head -20
        echo
    done
else
    echo "No segfaults or crash signals found."
fi

echo "=== Checking for postmaster crashes in TAP test logs ==="
# TAP tests store per-node logs under tmp_check/
tap_crashes=$(find "$SEARCHDIR" -path '*/tmp_check/*/log/postgresql*.log' \
    -exec grep -l "$crash_patterns\|TRAP:" {} \; 2>/dev/null)
if [ -n "$tap_crashes" ]; then
    found=1
    echo "FOUND crashes in TAP test logs:"
    for f in $tap_crashes; do
        echo "--- $f ---"
        grep -n "$crash_patterns\|TRAP:" "$f" | head -20
        echo
    done
else
    echo "No crashes in TAP test logs."
fi

echo ""
if [ "$found" -eq 1 ]; then
    echo "RESULT: Crash evidence detected."
    exit 1
else
    echo "RESULT: No crashes detected."
    exit 0
fi
