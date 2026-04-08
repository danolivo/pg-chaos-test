#!/bin/bash
# Scan all *.diffs files for lines containing '+ERROR' and print
# the file path followed by matching error lines.

found=0
while IFS= read -r -d '' dfile; do
    matches=$(grep -n '+ERROR' "$dfile")
    if [ -n "$matches" ]; then
        found=1
        echo "=== $dfile ==="
        echo "$matches"
        echo
    fi
done < <(find "${1:-.}" -name '*.diffs' -print0)

if [ "$found" -eq 0 ]; then
    echo "No +ERROR lines found in any .diffs files."
fi
