#!/bin/bash
# Scan all *.diffs files for lines containing '+ERROR',
# 'unrecognized node type', 'server closed the connection unexpectedly',
# or 'could not find pathkey item to sort'
# and print the file path followed by matching lines.

found=0
while IFS= read -r -d '' dfile; do
    matches=$(grep -n -e '+ERROR' -e 'unrecognized node type' -e 'server closed the connection unexpectedly' -e 'could not find pathkey item to sort' "$dfile")
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
