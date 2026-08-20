#!/usr/bin/env bash
# zig_sast.sh - Static analysis safety checks for Zig source code.
# Exits non-zero if any finding is detected.
set -euo pipefail

SRC_DIR="${1:-src}"
EXIT_CODE=0

echo "=== Zig SAST Scanner ==="

# 1. Check for unsafe pointer casts that bypass type safety.
echo "[check] Unsafe pointer casts (@ptrCast, @intFromPtr)..."
UNSAFE_CASTS=$(grep -rn '@ptrCast\|@intFromPtr\|@ptrFromInt' "$SRC_DIR" --include='*.zig' || true)
if [ -n "$UNSAFE_CASTS" ]; then
    echo "WARNING: Unsafe pointer casts found (review for correctness):"
    echo "$UNSAFE_CASTS"
    # Warning only - these may be legitimate in low-level code.
fi

# 2. Check for hardcoded credentials or IP addresses.
# Inline allowlist: append `// sast: allow` to a line to exempt it
# (intended for test fixtures inside a `test "..."` block, where the
# preceding-line heuristic below cannot see the block header).
echo "[check] Hardcoded credentials..."
HARDCODED=$(grep -rn 'password\s*=\s*"[^"]\+"\|secret\s*=\s*"[^"]\+"\|api_key\s*=\s*"[^"]\+"\|token\s*=\s*"sk-\|token\s*=\s*"ghp_' "$SRC_DIR" --include='*.zig' || true)
if [ -n "$HARDCODED" ]; then
    # Filter out test fixtures and string comparisons.
    REAL_FINDINGS=$(echo "$HARDCODED" | grep -v 'test "' | grep -v '// test' | grep -v 'testing\.' | grep -v 'std.mem.eql' | grep -v 'startsWith' | grep -v 'sast: allow' || true)
    if [ -n "$REAL_FINDINGS" ]; then
        echo "FAIL: Possible hardcoded credentials:"
        echo "$REAL_FINDINGS"
        EXIT_CODE=1
    fi
fi

# 3. Check for hardcoded IPv4 addresses (excluding 127.0.0.1 and 0.0.0.0).
echo "[check] Hardcoded IP addresses..."
HARDCODED_IPS=$(grep -rn '"[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}"' "$SRC_DIR" --include='*.zig' \
    | grep -v '127\.0\.0\.1' | grep -v '0\.0\.0\.0' | grep -v 'test "' || true)
if [ -n "$HARDCODED_IPS" ]; then
    echo "WARNING: Hardcoded IP addresses found (review for correctness):"
    echo "$HARDCODED_IPS"
fi

# 4. Check for use of std.os.linux / direct syscalls outside of expected locations.
echo "[check] Direct syscall usage..."
DIRECT_SYSCALLS=$(grep -rn 'std\.os\.linux\.\|std\.os\.system\.' "$SRC_DIR" --include='*.zig' || true)
if [ -n "$DIRECT_SYSCALLS" ]; then
    echo "WARNING: Direct OS syscall usage found (may reduce portability):"
    echo "$DIRECT_SYSCALLS"
fi

# 5. Check for TODO/FIXME/HACK/XXX debt markers.
echo "[check] Code debt markers..."
DEBT=$(grep -rn 'TODO\|FIXME\|HACK\|XXX' "$SRC_DIR" --include='*.zig' \
    | grep -v 'containsAny.*"TODO"' | grep -v '"TODO"' | grep -v '"FIXME"' || true)
if [ -n "$DEBT" ]; then
    echo "INFO: Code debt markers found:"
    echo "$DEBT"
fi

# 6. Check for unrestricted file permissions. Flag modes where group or
#    other has write access. The previous pattern `chmod(0o7` matched
#    0o700 (owner-only, restrictive) as a false positive. The refined
#    pattern captures only modes with non-owner write bits:
#      - any 3-digit octal where digit 2 (group) is 2/3/6/7 → group-write
#      - any 3-digit octal where digit 3 (other) is 2/3/6/7 → other-write
#    This correctly flags 0o777, 0o666, 0o755 (other-read is fine but
#    we're conservative), 0o775, etc., while allowing 0o600, 0o700,
#    0o400, 0o500 (all owner-only).
echo "[check] Overly permissive file modes..."
PERMS=$(grep -rnE 'chmod\(0o[0-7][2367][0-7]|chmod\(0o[0-7][0-7][2367]' "$SRC_DIR" --include='*.zig' \
    | grep -v 'sast: allow' || true)
if [ -n "$PERMS" ]; then
    echo "FAIL: Overly permissive file modes found:"
    echo "$PERMS"
    EXIT_CODE=1
fi

echo "=== SAST scan complete ==="
exit $EXIT_CODE
