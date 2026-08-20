#!/usr/bin/env bash
# check_dependency_pin.sh - Supply-chain gate.
#
# Fails if build.zig.zon declares any dependency whose name is not in
# scripts/ci/allowed_dependencies.txt. The allowlist starts empty; adding
# a name requires a reviewed change to that file, which becomes the
# audit trail for new transitive supply-chain surface.
set -euo pipefail

ZON="${1:-build.zig.zon}"
ALLOWLIST="${2:-scripts/ci/allowed_dependencies.txt}"

if [ ! -f "$ZON" ]; then
    echo "FAIL: manifest not found: $ZON" >&2
    exit 1
fi

# Extract the block between ".dependencies = .{" and the matching "}," .
# build.zig.zon is a trusted, in-repo file; we tolerate comments and
# whitespace but require a well-formed block.
block=$(awk '
    /\.dependencies[[:space:]]*=[[:space:]]*\.\{/ { inblock = 1; depth = 0 }
    inblock {
        for (i = 1; i <= length($0); i++) {
            c = substr($0, i, 1)
            if (c == "{") depth++
            else if (c == "}") {
                depth--
                if (depth == 0) { inblock = 0; break }
            }
        }
        print
    }
' "$ZON")

# Collect declared dependency names (keys like `.foo = .{ ... }`).
declared=$(printf '%s\n' "$block" \
    | grep -oE '\.[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*\.\{' \
    | sed -E 's/^\.([A-Za-z_][A-Za-z0-9_]*).*/\1/' \
    | grep -vE '^(dependencies|paths|name|version|fingerprint|minimum_zig_version)$' \
    || true)

if [ -z "$declared" ]; then
    echo "OK: build.zig.zon declares zero dependencies."
    exit 0
fi

# Load allowlist (strip comments / blanks).
allowed=""
if [ -f "$ALLOWLIST" ]; then
    allowed=$(grep -vE '^[[:space:]]*(#|$)' "$ALLOWLIST" || true)
fi

violations=""
while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    if ! printf '%s\n' "$allowed" | grep -Fxq "$dep"; then
        violations="${violations}${dep}"$'\n'
    fi
done <<< "$declared"

if [ -n "$violations" ]; then
    echo "FAIL: build.zig.zon declares dependencies not in $ALLOWLIST:" >&2
    printf '%s' "$violations" | sed 's/^/  - /' >&2
    echo >&2
    echo "To approve a new dependency, add its name to $ALLOWLIST in a" >&2
    echo "reviewed pull request. This file is the supply-chain audit trail." >&2
    exit 1
fi

echo "OK: all declared dependencies present in $ALLOWLIST."
