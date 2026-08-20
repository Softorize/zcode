#!/usr/bin/env bash
# generate_manpage.sh - Render a man(1) page from `zcode --help`.
#
# Output lands at docs/man/zcode.1. Ship the rendered file in the
# release tarball so `brew install zcode` (etc.) can place it at
# /usr/local/share/man/man1/zcode.1 without the installer having to
# shell out to zcode at install time.
#
# Usage: generate_manpage.sh [output_dir]
set -euo pipefail

OUTPUT_DIR="${1:-docs/man}"
BINARY="${ZCODE_BINARY:-./zig-out/bin/zcode}"

if [ ! -x "$BINARY" ]; then
    echo "FAIL: $BINARY not found or not executable. Run 'zig build' first or set ZCODE_BINARY." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
OUT="$OUTPUT_DIR/zcode.1"

VERSION=$("$BINARY" --version | awk '{print $2}')
DATE=$(date -u +%Y-%m-%d)
HELP=$("$BINARY" --help)

{
    printf '.TH ZCODE 1 "%s" "zcode %s" "User Commands"\n' "$DATE" "$VERSION"
    printf '.SH NAME\n'
    printf 'zcode \\- Enterprise coding agent CLI\n'
    printf '.SH SYNOPSIS\n'
    printf '.B zcode\n'
    printf '[\\fIOPTIONS\\fR] [\\fICOMMAND\\fR] [\\fIARGS\\fR]\n'
    printf '.SH DESCRIPTION\n'
    printf 'zcode is a command-line coding agent. It drives an LLM against a\n'
    printf 'workspace, executes tools (shell, file edits, git, MCP servers) on\n'
    printf 'the agent\\(aqs behalf, and can run fully interactively or in a\n'
    printf 'one-shot/JSON mode for scripting.\n'
    printf '.SH HELP OUTPUT\n'
    printf '.nf\n'
    # Escape backslashes and dots so groff does not interpret them.
    printf '%s\n' "$HELP" | sed -e 's/\\/\\\\/g' -e 's/^\./\\\&./g'
    printf '.fi\n'
    printf '.SH EXIT STATUS\n'
    printf '.TP\n'
    printf '.B 0\n'
    printf 'Success.\n'
    printf '.TP\n'
    printf '.B 1\n'
    printf 'Runtime error (provider failure, tool error, non-configuration problem).\n'
    printf '.TP\n'
    printf '.B 2\n'
    printf 'Invalid configuration, flags, or arguments; strict-mode violation.\n'
    printf '.TP\n'
    printf '.B 130\n'
    printf 'Interrupted by user (SIGINT / Ctrl+C).\n'
    printf '.SH FILES\n'
    printf '.TP\n'
    printf '.B ~/.zcode/config.toml\n'
    printf 'User configuration file.\n'
    printf '.TP\n'
    printf '.B /etc/zcode/managed.toml\n'
    printf 'System-level managed config (strict, highest precedence).\n'
    printf '.TP\n'
    printf '.B /etc/zcode/managed.d/*.toml\n'
    printf 'Sorted managed config drop-ins; later files win.\n'
    printf '.TP\n'
    printf '.B ~/.zcode/logs/audit-*.jsonl\n'
    printf 'HMAC-chained audit log.\n'
    printf '.SH ENVIRONMENT\n'
    printf '.TP\n'
    printf '.B NO_COLOR\n'
    printf 'If set (non-empty), suppresses ANSI color output.\n'
    printf '.TP\n'
    printf '.B ZCODE_*\n'
    printf 'All zcode-consumed environment variables are listed by \\fBzcode --list-env\\fR.\n'
    printf '.SH REPORTING BUGS\n'
    printf 'https://github.com/Softorize/zcode/issues\n'
    printf '.SH SEE ALSO\n'
    printf '\\fBgit\\fR(1), \\fBjq\\fR(1)\n'
} > "$OUT"

echo "Wrote $OUT ($(wc -l < "$OUT") lines)."
