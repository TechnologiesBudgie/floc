#!/bin/bash
# FLOC benchmark script — compare against cloc if available

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOC="$SCRIPT_DIR/floc"

if [[ ! -x "$FLOC" ]]; then
    echo "ERROR: $FLOC not found. Run 'make' first."
    exit 1
fi

TARGET="${1:-.}"
echo "=== FLOC benchmark on: $TARGET ==="
echo ""

START=$(date +%s%N)
"$FLOC" "$TARGET"
END=$(date +%s%N)
FLOC_MS=$(( (END - START) / 1000000 ))
echo ""
echo "FLOC wall time: ${FLOC_MS} ms"

if command -v cloc &>/dev/null; then
    echo ""
    echo "=== cloc benchmark ==="
    START=$(date +%s%N)
    cloc "$TARGET"
    END=$(date +%s%N)
    CLOC_MS=$(( (END - START) / 1000000 ))
    echo ""
    echo "cloc wall time: ${CLOC_MS} ms"
    echo ""
    if [[ $CLOC_MS -gt 0 ]]; then
        RATIO=$(echo "scale=1; $CLOC_MS / $FLOC_MS" | bc 2>/dev/null || echo "N/A")
        echo "FLOC is ${RATIO}x faster than cloc"
    fi
else
    echo ""
    echo "(cloc not found — install with: sudo apt install cloc / brew install cloc)"
fi
