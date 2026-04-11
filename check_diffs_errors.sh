#!/bin/bash
# Scan all *.diffs files for lines containing '+ERROR',
# 'unrecognized node type', or 'server closed the connection
# unexpectedly' and print the file path followed by matching lines.

found=0
while IFS= read -r -d '' dfile; do
    matches=$(grep -n -e '+ERROR' -e 'unrecognized node type' -e 'server closed the connection unexpectedly' "$dfile")
    if [ -n "$matches" ]; then
        found=1
        echo "=== $dfile ==="
        echo "$matches"
        echo
    fi
done < <(find "${1:-.}" -name '*.diffs' -print0)

if [ "$found" -eq 0 ]; then
    echo "No error patterns found in any .diffs files."
fi
