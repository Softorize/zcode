#!/usr/bin/env bash
# CLI smoke test. Walks every user-visible surface that a first-run
# user would hit and confirms:
#   - top-level --help and --version both emit to stdout
#   - every group-help surface prints its own header (no accidental
#     fallback to the global help block)
#   - NO_COLOR / --no-color suppress ANSI escapes on stdout
#   - every "remove-a-resource" command exits non-zero when the
#     resource does not exist (policy set in audit pass 11)
#   - exit code is 2 for parse errors (unknown flags) and 1 for
#     missing-resource errors
#
# Run via `scripts/ci/cli_smoke.sh` from a repo checkout. Expects the
# binary at $ZCODE_BIN (defaults to zig-out/bin/zcode then
# ~/.local/bin/zcode). Safe to run in CI: uses an isolated HOME so it
# cannot touch the caller's ~/.zcode.

set -euo pipefail

BIN="${ZCODE_BIN:-}"
if [ -z "$BIN" ]; then
  if [ -x zig-out/bin/zcode ]; then
    BIN=zig-out/bin/zcode
  elif [ -x "$HOME/.local/bin/zcode" ]; then
    BIN="$HOME/.local/bin/zcode"
  else
    echo "zcode binary not found; set ZCODE_BIN" >&2
    exit 2
  fi
fi

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

# Isolated HOME so the smoke test cannot read or mutate the operator's
# real ~/.zcode, ~/Library/Application Support/zcode, or XDG dirs.
export HOME="$tmp"
export XDG_CONFIG_HOME="$tmp/.config"
export XDG_DATA_HOME="$tmp/.local/share"
export XDG_STATE_HOME="$tmp/.local/state"
unset ZCODE_CONFIG || true
unset ZCODE_MANAGED_CONFIG || true
unset ZCODE_API_AUTH_REQUIRED || true

pass=0
fail=0
check() {
  local name="$1"; shift
  if "$@"; then
    pass=$((pass + 1))
    printf '  ok  %s\n' "$name"
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n' "$name"
  fi
}

has_text() {
  local file="$1" needle="$2"
  grep -qF -- "$needle" "$file"
}

exit_code_is() {
  local expected="$1"; shift
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  [ "$actual" = "$expected" ]
}

printf '==> zcode CLI smoke (%s)\n' "$BIN"

# --- 1. version + top-level help --------------------------------------
v_out="$tmp/version.txt"
"$BIN" --version >"$v_out" 2>&1
check "--version emits 'zcode <semver>'" grep -Eq '^zcode [0-9]+\.[0-9]+\.[0-9]+' "$v_out"

h_out="$tmp/help.txt"
"$BIN" --help >"$h_out" 2>&1
check "--help contains 'Getting started'" has_text "$h_out" "Getting started"
check "--help contains exit-code legend" has_text "$h_out" "Exit codes"

# --- 2. group help --------------------------------------------------
# Each group should emit its own "zcode <group> - <blurb>" header when
# invoked bare. Adding a new group to args.zig should also add a line
# here so we catch accidental fallthrough to the global help text.
groups=(
  mcp
  keychain
  audit
  session
  providers
  trust
  agents
  daemon
  hooks
  marketplace
  plugins
  commands
  skills
  policy
)
for g in "${groups[@]}"; do
  out="$tmp/group_$g.txt"
  "$BIN" "$g" >"$out" 2>&1 || true
  check "group help: zcode $g" grep -qE "^zcode $g - " "$out"
done

# --- 3. color / tty behavior ----------------------------------------
# --help is piped, so --no-color and NO_COLOR must produce byte-for-byte
# identical output (no ANSI escape bytes anywhere).
"$BIN" --help >"$tmp/plain.txt" 2>&1
check "no ANSI escapes on piped --help" \
  bash -c "! grep -q $'\x1b\[' '$tmp/plain.txt'"
NO_COLOR=1 "$BIN" --help >"$tmp/nocolor.txt" 2>&1
check "NO_COLOR stable help output" cmp -s "$tmp/plain.txt" "$tmp/nocolor.txt"
"$BIN" --no-color --help >"$tmp/flag.txt" 2>&1
check "--no-color stable help output" cmp -s "$tmp/plain.txt" "$tmp/flag.txt"

# Prompt diagnostics are used to debug context bloat and prompt-routing
# failures. They must remain machine-readable and pipe-friendly.
prompt_inspect_json="$tmp/prompt_inspect.json"
"$BIN" prompt inspect --json --summary "fix tests" >"$prompt_inspect_json" 2>&1
check "prompt inspect summary marks preprocessor skipped" has_text "$prompt_inspect_json" '"preprocessor_skipped":true'
check "prompt inspect summary omits prompt packets" \
  bash -c "! grep -q '\"system_prompt\"' '$prompt_inspect_json' && ! grep -q '\"user_prompt_packet\"' '$prompt_inspect_json'"
check "prompt inspect tolerates closed stdout pipe" \
  bash -o pipefail -c '"$1" prompt inspect --json "fix tests" | head -c 80 >/dev/null' bash "$BIN"

release_dist="$tmp/release-dist"
release_out="$tmp/release-out"
mkdir -p "$release_dist" "$release_out"
for asset in zcode-linux-x86_64 zcode-linux-aarch64 zcode-macos-x86_64 zcode-macos-aarch64; do
  printf 'fake binary %s\n' "$asset" > "$release_dist/$asset"
  printf 'fake signature %s\n' "$asset" > "$release_dist/$asset.sig"
  printf 'fake cert %s\n' "$asset" > "$release_dist/$asset.pem"
  printf 'fake sigstore bundle %s\n' "$asset" > "$release_dist/$asset.bundle"
done
printf 'fake slsa provenance\n' > "$release_dist/zcode.intoto.jsonl"
printf '{"bomFormat":"CycloneDX"}\n' > "$release_out/sbom.cdx.json"
printf 'fake sbom signature\n' > "$release_out/sbom.cdx.json.sig"
printf 'fake sbom cert\n' > "$release_out/sbom.cdx.json.pem"
printf 'fake sbom bundle\n' > "$release_out/sbom.cdx.json.bundle"
bash scripts/release/generate_release_metadata.sh 1.2.3 example/zcode "$release_dist" "$release_out" >/dev/null 2>/dev/null
check "release update manifest excludes signature sidecars" \
  bash -c "! grep -qE '\\.(sig|pem|bundle)' '$release_out/update.json'"
check "release checksums include signature sidecars" \
  bash -c "grep -q 'zcode-linux-x86_64.sig' '$release_out/SHA256SUMS' && grep -q 'zcode-linux-x86_64.pem' '$release_out/SHA256SUMS' && grep -q 'zcode-linux-x86_64.bundle' '$release_out/SHA256SUMS'"
check "release checksums include provenance and SBOM" \
  bash -c "grep -q 'zcode.intoto.jsonl' '$release_out/SHA256SUMS' && grep -q 'sbom.cdx.json' '$release_out/SHA256SUMS' && grep -q 'sbom.cdx.json.sig' '$release_out/SHA256SUMS' && grep -q 'sbom.cdx.json.bundle' '$release_out/SHA256SUMS'"

airgap_src="$tmp/airgap-src"
airgap_out="$tmp/airgap-out"
mkdir -p "$airgap_src/release" "$airgap_out"
printf 'fake binary\n' > "$airgap_src/zcode-linux-x86_64"
printf 'fake signature\n' > "$airgap_src/zcode-linux-x86_64.sig"
printf 'fake cert\n' > "$airgap_src/zcode-linux-x86_64.pem"
printf 'fake sigstore bundle\n' > "$airgap_src/zcode-linux-x86_64.bundle"
check "airgap bundle requires SBOM/provenance artifacts" \
  bash -c "! bash scripts/release/airgap_bundle.sh 1.2.3 linux-x86_64 '$airgap_src' '$airgap_out' >/dev/null 2>'$tmp/airgap_missing.err' && grep -q 'missing required supply-chain artifact' '$tmp/airgap_missing.err'"
printf '{"bomFormat":"CycloneDX"}\n' > "$airgap_src/release/sbom.cdx.json"
printf 'fake sbom signature\n' > "$airgap_src/release/sbom.cdx.json.sig"
printf 'fake sbom cert\n' > "$airgap_src/release/sbom.cdx.json.pem"
printf 'fake sbom bundle\n' > "$airgap_src/release/sbom.cdx.json.bundle"
printf 'fake slsa provenance\n' > "$airgap_src/zcode.intoto.jsonl"
bash scripts/release/airgap_bundle.sh 1.2.3 linux-x86_64 "$airgap_src" "$airgap_out" >/dev/null 2>/dev/null
check "airgap bundle creates strict installer archive" \
  bash -c "tar -xzf '$airgap_out/zcode-1.2.3-linux-x86_64-airgap.tar.gz' -C '$tmp' && grep -q 'refusing air-gap install' '$tmp/zcode-1.2.3-linux-x86_64-airgap/install.sh'"

# --- 4. exit codes ---------------------------------------------------
check "unknown flag exits 2" exit_code_is 2 "$BIN" --this-flag-does-not-exist

# Every "remove-a-resource" command exits 1 when the resource is not
# found. This matches the policy tightened across audit passes 9-11;
# regressions here would silently mask mistakes in scripts.
check "keychain delete missing exits 1" \
  exit_code_is 1 "$BIN" keychain delete zcode-smoke-missing
check "mcp remove missing exits 1" \
  exit_code_is 1 "$BIN" mcp remove zcode-smoke-missing
check "plugins uninstall missing exits 1" \
  exit_code_is 1 "$BIN" plugins uninstall zcode-smoke-missing
check "commands uninstall missing exits 1" \
  exit_code_is 1 "$BIN" commands uninstall zcode-smoke-missing
check "trust revoke missing exits 1" \
  exit_code_is 1 "$BIN" trust revoke /nonexistent/zcode-smoke
check "trust hook-revoke missing exits 1" \
  exit_code_is 1 "$BIN" trust hook-revoke /nonexistent/zcode-smoke
check "trust marketplace-unblock missing exits 1" \
  exit_code_is 1 "$BIN" trust marketplace-unblock zcode-smoke-missing
check "marketplace remove missing exits 1" \
  exit_code_is 1 "$BIN" marketplace remove zcode-smoke-missing

# Successful no-op reads should still return 0 even on a fresh install.
check "mcp list on fresh install exits 0" "$BIN" mcp list
check "trust status on fresh install exits 0" "$BIN" trust status
check "policy show on fresh install exits 0" "$BIN" policy show

# Per-subcommand required-argument checks. Each should exit 2 with a
# targeted "error: <cmd>: missing <arg>" line on stderr instead of
# tumbling into a Zig error enum deep inside the MCP client.
usage_err_has() {
  local expected="$1"; shift
  local out
  out="$("$@" 2>&1 1>/dev/null || true)"
  [[ "$out" == *"$expected"* ]]
}
check "mcp read w/o server: clean usage error" \
  usage_err_has "error: mcp read: missing <server>" "$BIN" mcp read
check "mcp read w/o uri: clean usage error" \
  usage_err_has "error: mcp read: missing <uri>" "$BIN" mcp read server-name
check "mcp remove w/o name: clean usage error" \
  usage_err_has "error: mcp remove: missing <name>" "$BIN" mcp remove
check "mcp test w/o name: clean usage error" \
  usage_err_has "error: mcp test: missing <name>" "$BIN" mcp test
check "mcp read w/o server exits 2" exit_code_is 2 "$BIN" mcp read
check "mcp remove w/o name exits 2" exit_code_is 2 "$BIN" mcp remove

# Usage errors from late-binding handlers must reach exit 2 too and
# keep the banner out of stdout so `zcode completion bogus > out.sh`
# doesn't silently install an empty file.
check "completion bogus exits 2" exit_code_is 2 "$BIN" completion bogus
check "completion bogus banner is on stderr" \
  usage_err_has "error: completion: unrecognized shell" "$BIN" completion bogus
check "completion bogus writes nothing to stdout" \
  bash -c "[ -z \"\$('$BIN' completion bogus 2>/dev/null)\" ]"
check "review bogus exits 2" exit_code_is 2 "$BIN" review bogus
check "review bogus banner is on stderr" \
  usage_err_has "error: review:" "$BIN" review bogus

# Session and daemon subcommands that need a session id used to fall
# through to the agent runtime and surface a bare "MissingSessionId
# (provider=..., model=...)" error that looked like a provider crash.
# Parser catches them now.
check "session compact w/o id: clean usage error" \
  usage_err_has "error: session compact: missing" "$BIN" session compact
check "session export w/o id: clean usage error" \
  usage_err_has "error: session export: missing" "$BIN" session export
check "session resume w/o id: clean usage error" \
  usage_err_has "error: session resume: missing" "$BIN" session resume
check "session import w/o bundle: clean usage error" \
  usage_err_has "error: session import: missing" "$BIN" session import
check "session restore w/o label: clean usage error" \
  usage_err_has "error: session restore: missing" "$BIN" session restore abc123
check "daemon handoff w/o id: clean usage error" \
  usage_err_has "error: daemon handoff: missing" "$BIN" daemon handoff
check "session compact w/o id exits 2" exit_code_is 2 "$BIN" session compact
check "daemon handoff w/o id exits 2" exit_code_is 2 "$BIN" daemon handoff

# Pass-20 sweep of remaining <name>-required subcommands.
check "plugins install w/o name: clean usage error" \
  usage_err_has "error: plugins install: missing" "$BIN" plugins install
check "commands run w/o name: clean usage error" \
  usage_err_has "error: commands run: missing" "$BIN" commands run
check "agents show w/o name: clean usage error" \
  usage_err_has "error: agents show: missing" "$BIN" agents show
check "skills show w/o name: clean usage error" \
  usage_err_has "error: skills show: missing" "$BIN" skills show
check "trust hook-allow w/o path: clean usage error" \
  usage_err_has "error: trust hook-allow: missing" "$BIN" trust hook-allow
check "trust marketplace-allow w/o prefix: clean usage error" \
  usage_err_has "error: trust marketplace-allow: missing" "$BIN" trust marketplace-allow
check "mcp auth login w/o server: clean usage error" \
  usage_err_has "error: mcp auth login: missing" "$BIN" mcp auth login
check "marketplace add w/o args: clean usage error" \
  usage_err_has "error: marketplace add: missing" "$BIN" marketplace add
check "plugins install w/o name exits 2" exit_code_is 2 "$BIN" plugins install
check "agents show w/o name exits 2" exit_code_is 2 "$BIN" agents show
check "mcp auth login w/o server exits 2" exit_code_is 2 "$BIN" mcp auth login

# Runtime not-found errors on session-by-id commands used to leak as
# `FileNotFound (provider=..., model=...)` -- now caught by
# assertSessionExists + main.zig's per-command switch and exit 2.
check "session compact <missing-id>: clean no-such-session" \
  usage_err_has "error: session compact: no such session" "$BIN" session compact zzzz-nonexistent
check "session export <missing-id>: clean no-such-session" \
  usage_err_has "error: session export: no such session" "$BIN" session export zzzz-nonexistent
check "session share <missing-id>: clean no-such-session" \
  usage_err_has "error: session share: no such session" "$BIN" session share zzzz-nonexistent
check "session fork <missing-id>: clean no-such-session" \
  usage_err_has "error: session fork: no such session" "$BIN" session fork zzzz-nonexistent
check "session compact <missing-id> exits 2" \
  exit_code_is 2 "$BIN" session compact zzzz-nonexistent
check "audit verify <missing-file>: clean error" \
  usage_err_has "error: audit verify: file not found" "$BIN" audit verify /nonexistent/zcode-smoke
check "audit verify <missing-file> exits 2" \
  exit_code_is 2 "$BIN" audit verify /nonexistent/zcode-smoke

# Pass-22 sweep: the remaining "valid syntax, missing resource"
# paths (plugin not installed, command not installed, session id
# that doesn't exist on disk for commands that still went through
# the agent runtime). All now short-circuit with a targeted error.
check "daemon handoff <bad-id>: clean no-such-session" \
  usage_err_has "error: daemon handoff: no such session" "$BIN" daemon handoff zzzz-nonexistent
check "session checkpoints <bad-id>: clean no-such-session" \
  usage_err_has "error: session checkpoints: no such session" "$BIN" session checkpoints zzzz-nonexistent
check "plugins show <bad-name>: clean not-installed" \
  usage_err_has "error: plugins show: plugin" "$BIN" plugins show zcode-smoke-missing
check "plugins update <bad-name>: clean not-installed" \
  usage_err_has "error: plugins update: plugin" "$BIN" plugins update zcode-smoke-missing
check "commands show <bad-name>: clean not-installed" \
  usage_err_has "error: commands show: command" "$BIN" commands show zcode-smoke-missing
check "commands run <bad-name>: clean not-installed" \
  usage_err_has "error: commands run: command" "$BIN" commands run zcode-smoke-missing
check "commands update <bad-name>: clean not-installed" \
  usage_err_has "error: commands update: command" "$BIN" commands update zcode-smoke-missing
check "trust hook-allow <missing-file>: clean error" \
  usage_err_has "error: trust hook-allow: file not found" "$BIN" trust hook-allow /nonexistent/zcode-smoke
check "daemon handoff <bad-id> exits 2" \
  exit_code_is 2 "$BIN" daemon handoff zzzz-nonexistent
check "plugins show <bad-name> exits 1" \
  exit_code_is 1 "$BIN" plugins show zcode-smoke-missing
check "commands run <bad-name> exits 1" \
  exit_code_is 1 "$BIN" commands run zcode-smoke-missing
check "trust hook-allow <missing-file> exits 2" \
  exit_code_is 2 "$BIN" trust hook-allow /nonexistent/zcode-smoke

# Pass-23: the plaintext-API-key warning used to fire in every process
# that loaded config.toml, including scripted pipelines. Now silenced
# under --quiet / --json / --log-level=error; still fires by default.
# We inject a fake plaintext key so the test works on any machine.
setup_plaintext_cfg() {
  local cfgdir="$tmp/.zcode"
  mkdir -p "$cfgdir"
  cat > "$cfgdir/config.toml" <<'EOF'
provider_api_key = "sk-test-plaintext-for-smoke"
EOF
}
setup_plaintext_cfg

# No-flag default: warning should be on stderr (invoke a fast read-only
# command so we don't stall on anything network-bound).
check "plaintext warning fires by default" \
  bash -c "out=\$('$BIN' policy show 2>&1 1>/dev/null); echo \"\$out\" | grep -q 'appears to hold a plaintext'"
check "--quiet silences plaintext warning" \
  bash -c "out=\$('$BIN' --quiet policy show 2>&1 1>/dev/null); ! echo \"\$out\" | grep -q 'appears to hold a plaintext'"
check "--json silences plaintext warning" \
  bash -c "out=\$('$BIN' --json policy show 2>&1 1>/dev/null); ! echo \"\$out\" | grep -q 'appears to hold a plaintext'"
check "--log-level error silences plaintext warning" \
  bash -c "out=\$('$BIN' --log-level error policy show 2>&1 1>/dev/null); ! echo \"\$out\" | grep -q 'appears to hold a plaintext'"

# Pass-24: invalid flag values now print the list of valid options,
# instead of dumping the Zig error enum name ("InvalidSandboxProfile")
# and leaving the user to grep source.
check "invalid --sandbox prints valid set" \
  usage_err_has "Expected one of: read-only, workspace-write" "$BIN" --sandbox nope policy show
check "invalid --approval-mode prints valid set" \
  usage_err_has "Expected one of: tiered-auto, manual, strict" "$BIN" --approval-mode maybe policy show
check "invalid --provider prints valid set" \
  usage_err_has "Expected one of: openai, anthropic, gemini" "$BIN" --provider bogus policy show
apiauthhome="$tmp/apiauthhome"
mkdir -p "$apiauthhome/.zcode"
printf 'api_auth_required = true\n' > "$apiauthhome/.zcode/config.toml"
check "invalid API auth config names OIDC RS256 options" \
  usage_err_has "complete OIDC settings (HS256 secret or RS256 JWKS json/file/url)" env HOME="$apiauthhome" "$BIN" policy show
check "invalid --sandbox exits 2" \
  exit_code_is 2 "$BIN" --sandbox nope policy show
check "invalid --approval-mode exits 2" \
  exit_code_is 2 "$BIN" --approval-mode maybe policy show

# Pass-25: contradictory flag pairs used to both be accepted silently
# with an arbitrary winner (last-flag-wins) that hid typos.
check "--verbose --quiet rejected" \
  usage_err_has "--verbose and --quiet are contradictory" "$BIN" --verbose --quiet policy show
check "--verbose --quiet exits 2" \
  exit_code_is 2 "$BIN" --verbose --quiet policy show
check "--yolo --strict rejected" \
  usage_err_has "--yolo and --strict are contradictory" "$BIN" --yolo --strict policy show
check "--yolo --strict exits 2" \
  exit_code_is 2 "$BIN" --yolo --strict policy show
check "--approve-high --strict rejected" \
  usage_err_has "--approve-high and --strict are contradictory" "$BIN" --approve-high --strict policy show

# Pass-26: keychain set/get/delete used to write "usage:" to stdout and
# exit 0 on missing args, which made `zcode keychain set > script.sh`
# produce a bogus shell snippet.
check "keychain set w/o args: clean usage error" \
  usage_err_has "error: keychain set: missing <provider>" "$BIN" keychain set
check "keychain set w/o secret: clean usage error" \
  usage_err_has "error: keychain set: missing <secret>" "$BIN" keychain set openai
check "keychain set w/ too many args: quoted-secret hint" \
  usage_err_has "too many arguments" "$BIN" keychain set openai sk-abc def
check "keychain get w/o provider: clean usage error" \
  usage_err_has "error: keychain get: missing <provider>" "$BIN" keychain get
check "keychain set w/o args exits 2" \
  exit_code_is 2 "$BIN" keychain set
check "keychain get w/o args exits 2" \
  exit_code_is 2 "$BIN" keychain get
check "keychain set w/ too many args exits 2" \
  exit_code_is 2 "$BIN" keychain set a b c d

# Pass-27: mcp <cmd> <unknown-server> used to leak
# `ServerNotFound (provider=..., model=...)` through the agent runtime.
# Now validated up front by assertMcpServerKnown.
check "mcp tools <bad-server>: clean not-found" \
  usage_err_has "error: mcp tools: server 'zzzz-missing' not found" "$BIN" mcp tools zzzz-missing
check "mcp test <bad-server>: clean not-found" \
  usage_err_has "error: mcp test: server 'zzzz-missing' not found" "$BIN" mcp test zzzz-missing
check "mcp auth login <bad-server>: clean not-found" \
  usage_err_has "error: mcp auth login: server 'zzzz-missing' not found" "$BIN" mcp auth login zzzz-missing
check "mcp auth logout <bad-server>: clean not-found" \
  usage_err_has "error: mcp auth logout: server 'zzzz-missing' not found" "$BIN" mcp auth logout zzzz-missing
check "mcp read <bad-server>: clean not-found" \
  usage_err_has "error: mcp read: server 'zzzz-missing' not found" "$BIN" mcp read zzzz-missing file://x
check "mcp tools <bad-server> exits 1" \
  exit_code_is 1 "$BIN" mcp tools zzzz-missing
check "mcp test <bad-server> exits 1" \
  exit_code_is 1 "$BIN" mcp test zzzz-missing
check "mcp auth login <bad-server> exits 1" \
  exit_code_is 1 "$BIN" mcp auth login zzzz-missing

# Pass-28: audit verify on a directory path, and session restore/undo
# with a bogus checkpoint label, used to leak IsDir or CheckpointNotFound
# through the agent runtime envelope.
check "audit verify <directory>: clean error" \
  usage_err_has "path is a directory" "$BIN" audit verify /tmp
check "audit verify <directory> exits 2" \
  exit_code_is 2 "$BIN" audit verify /tmp
badkeyhome="$tmp/badauditkey"
mkdir -p "$badkeyhome/.config/zcode/logs"
printf 'short' > "$badkeyhome/.config/zcode/logs/hmac.key"
chmod 0600 "$badkeyhome/.config/zcode/logs/hmac.key"
check "audit startup rejects malformed HMAC key" \
  usage_err_has "InvalidHmacKey" env HOME="$badkeyhome" XDG_CONFIG_HOME="$badkeyhome/.config" "$BIN" policy show
printf '12345678901234567890123456789012' > "$badkeyhome/.config/zcode/logs/hmac.key"
chmod 0644 "$badkeyhome/.config/zcode/logs/hmac.key"
check "audit startup rejects readable HMAC key" \
  usage_err_has "InsecureHmacKeyPermissions" env HOME="$badkeyhome" XDG_CONFIG_HOME="$badkeyhome/.config" "$BIN" policy show

badpolhome="$tmp/badpolicy"
mkdir -p "$badpolhome/.config/zcode/policy"
printf 'allow_network = maybe\n' > "$badpolhome/.config/zcode/policy/policy.toml"
check "policy invalid bool: targeted error" \
  usage_err_has "policy error in" env HOME="$badpolhome" XDG_CONFIG_HOME="$badpolhome/.config" "$BIN" policy validate
check "policy invalid bool exits 2" \
  exit_code_is 2 env HOME="$badpolhome" XDG_CONFIG_HOME="$badpolhome/.config" "$BIN" policy validate
printf 'not_a_real_key = true\n' > "$badpolhome/.config/zcode/policy/policy.toml"
check "policy unknown key: targeted error" \
  usage_err_has "unknown key. Expected default_approval_mode" env HOME="$badpolhome" XDG_CONFIG_HOME="$badpolhome/.config" "$BIN" policy validate

# Pass-29: session id with DEL (0x7f) control byte used to print the
# raw char in the error. Now escaped with \xHH.
check "session compact <id-with-DEL>: escaped in error" \
  bash -c "out=\$('$BIN' session compact \$'abc\\x7fdef' 2>&1 1>/dev/null); echo \"\$out\" | grep -q 'abc\\\\x7fdef'"
# Very long id is truncated in the error message.
check "session compact <300-char id>: truncated in error" \
  bash -c "longid=\$(printf 'a%.0s' {1..300}); out=\$('$BIN' session compact \"\$longid\" 2>&1 1>/dev/null); echo \"\$out\" | grep -q '(300 chars total)'"

# Pass-30: -v short flag used to be dead (fell through to positional
# as an "unknown subcommand"), and other unknown single-char short
# flags masqueraded as "unrecognized subcommand" instead of the
# accurate "unrecognized flag". Both now fixed.
check "-v short flag activates verbose (accepted, exits 0)" \
  "$BIN" -v policy show
check "-x unknown short flag: clean 'unrecognized flag'" \
  bash -c "out=\$('$BIN' -x 2>&1 1>/dev/null | head -1); [[ \"\$out\" == *'unrecognized flag'* ]]"
check "-x unknown short flag exits 2" \
  exit_code_is 2 "$BIN" -x

# Pass-31: `mcp notifications <unknown-server>` silently printed
# "no MCP notifications" and exit 0; now validated up front.
check "mcp notifications <bad-server>: clean not-found" \
  usage_err_has "error: mcp notifications: server 'zzzz-missing' not found" "$BIN" mcp notifications zzzz-missing
check "mcp notifications <bad-server> exits 1" \
  exit_code_is 1 "$BIN" mcp notifications zzzz-missing

# Pass-32: a UTF-8 BOM at the start of config.toml (Windows editors)
# used to make the first key parse as '<BOM>default_model' and get
# silently dropped with an "unknown key" warning.
bomdir="$tmp/bomcfg"
mkdir -p "$bomdir/.zcode"
printf '\xef\xbb\xbfdefault_provider = "openai"\ndefault_model = "bomtest"\n' > "$bomdir/.zcode/config.toml"
check "config with UTF-8 BOM parses the first key cleanly" \
  bash -c "out=\$(HOME='$bomdir' '$BIN' config show 2>/dev/null); echo \"\$out\" | grep -q bomtest && ! echo \"\$out\" | grep -q 'unknown key'"

# Pass-33: a trailing TOML-style `# comment` on a value used to be
# merged into the value (because stripQuotes saw an unbalanced pair
# with the comment appended). Now stripped when the `#` is outside
# any quoted string.
cmtdir="$tmp/cmtcfg"
mkdir -p "$cmtdir/.zcode"
printf 'default_model = "clean-model" # trailing comment\n' > "$cmtdir/.zcode/config.toml"
check "config trailing # comment is stripped" \
  bash -c "out=\$(HOME='$cmtdir' '$BIN' config show 2>/dev/null); echo \"\$out\" | grep -q '^default_model = \"clean-model\"$'"

# And a `#` that's actually inside the string (common in issue/branch
# names like `issue-#42`) must NOT be stripped.
printf 'default_model = "issue-#42"\n' > "$cmtdir/.zcode/config.toml"
check "config # inside quoted string is preserved" \
  bash -c "out=\$(HOME='$cmtdir' '$BIN' config show 2>/dev/null); echo \"\$out\" | grep -q '^default_model = \"issue-#42\"$'"

# Managed settings v2: base managed.toml plus sorted managed.d/*.toml
# drop-ins, strict schema validation, and lockable enterprise keys.
managedv2dir="$tmp/managedv2"
managedhome="$tmp/managedhome"
mkdir -p "$managedv2dir/managed.d" "$managedhome"
printf 'api_profile = "read-only"\napi_auth_required = false\n' > "$managedv2dir/managed.toml"
printf 'api_profile = "editor"\nupdate_require_signature = true\n' > "$managedv2dir/managed.d/20-update.toml"
check "managed drop-ins override base config and report sources" \
  bash -c "out=\$(env HOME='$managedhome' ZCODE_MANAGED_CONFIG='$managedv2dir/managed.toml' '$BIN' config show 2>/dev/null); echo \"\$out\" | grep -q '^api_profile = \"editor\"$' && echo \"\$out\" | grep -q '^update_require_signature = true$' && echo \"\$out\" | grep -q 'managed.d/20-update.toml'"
check "config path prints managed drop-in directory" \
  bash -c "out=\$(env HOME='$managedhome' ZCODE_MANAGED_CONFIG='$managedv2dir/managed.toml' '$BIN' config path 2>/dev/null); echo \"\$out\" | grep -q '^managed_dropins  = .*/managed.d'"
check "managed lock blocks API auth env override" \
  bash -c "printf '{\"id\":1,\"method\":\"status\"}\\n' | env HOME='$managedhome' ZCODE_MANAGED_CONFIG='$managedv2dir/managed.toml' ZCODE_API_AUTH_REQUIRED=1 '$BIN' api serve 2>/dev/null | grep -q '\"ok\":true'"

badmanageddir="$tmp/badmanaged"
mkdir -p "$badmanageddir" "$tmp/badmanagedhome"
printf 'api_auth_required = true\ntypo_enterprise_policy = true\n' > "$badmanageddir/managed.toml"
check "managed config unknown key fails closed with targeted error" \
  usage_err_has "managed config error: unknown key 'typo_enterprise_policy'" env HOME="$tmp/badmanagedhome" ZCODE_MANAGED_CONFIG="$badmanageddir/managed.toml" "$BIN" config show
check "managed config unknown key exits 2" \
  exit_code_is 2 env HOME="$tmp/badmanagedhome" ZCODE_MANAGED_CONFIG="$badmanageddir/managed.toml" "$BIN" config show

badmanagedhashdir="$tmp/badmanagedhash"
mkdir -p "$badmanagedhashdir" "$tmp/badmanagedhashhome"
printf 'api_auth_required = true\n' > "$badmanagedhashdir/managed.toml"
printf '0000000000000000000000000000000000000000000000000000000000000000\n' > "$badmanagedhashdir/managed.toml.sha256"
check "managed config sha256 mismatch fails closed" \
  usage_err_has "Sha256SidecarMismatch" env HOME="$tmp/badmanagedhashhome" ZCODE_MANAGED_CONFIG="$badmanagedhashdir/managed.toml" "$BIN" config show
check "managed config sha256 mismatch exits 2" \
  exit_code_is 2 env HOME="$tmp/badmanagedhashhome" ZCODE_MANAGED_CONFIG="$badmanagedhashdir/managed.toml" "$BIN" config show

badmanagedsidecardir="$tmp/badmanagedsidecar"
mkdir -p "$badmanagedsidecardir" "$tmp/badmanagedsidecarhome"
printf 'api_auth_required = true\n' > "$badmanagedsidecardir/managed.toml"
printf 'bad-sidecar\n' > "$badmanagedsidecardir/managed.toml.sha256"
chmod 0666 "$badmanagedsidecardir/managed.toml.sha256"
check "managed config writable sha256 sidecar fails closed" \
  usage_err_has "UntrustedSha256SidecarPermissions" env HOME="$tmp/badmanagedsidecarhome" ZCODE_MANAGED_CONFIG="$badmanagedsidecardir/managed.toml" "$BIN" config show
check "managed config writable sha256 sidecar exits 2" \
  exit_code_is 2 env HOME="$tmp/badmanagedsidecarhome" ZCODE_MANAGED_CONFIG="$badmanagedsidecardir/managed.toml" "$BIN" config show

doctorpermhome="$tmp/doctorpermhome"
mkdir -p "$doctorpermhome"
chmod 0666 "$managedv2dir/managed.toml"
check "enterprise doctor fails group/world writable managed config" \
  bash -c "out=\$(env HOME='$doctorpermhome' ZCODE_MANAGED_CONFIG='$managedv2dir/managed.toml' '$BIN' doctor enterprise --json 2>/dev/null || true); echo \"\$out\" | grep -q '\"id\":\"managed_config_permissions\",\"status\":\"fail\"'"
chmod 0644 "$managedv2dir/managed.toml"
printf 'api_bearer_token = "secret-token"\n' > "$managedv2dir/managed.d/30-secret.toml"
chmod 0644 "$managedv2dir/managed.d/30-secret.toml"
check "enterprise doctor warns on world-readable secret managed drop-in" \
  bash -c "out=\$(env HOME='$doctorpermhome' ZCODE_MANAGED_CONFIG='$managedv2dir/managed.toml' '$BIN' doctor enterprise --json 2>/dev/null || true); echo \"\$out\" | grep -q '\"id\":\"managed_dropin_permissions\",\"status\":\"warn\"'"
rm -f "$managedv2dir/managed.d/30-secret.toml"

jwksdoctorhome="$tmp/jwksdoctorhome"
mkdir -p "$jwksdoctorhome/.zcode"
printf '{"keys":[]}\n' > "$jwksdoctorhome/jwks.json"
chmod 0666 "$jwksdoctorhome/jwks.json"
printf 'api_auth_required = true\napi_oidc_issuer = "https://idp.example"\napi_oidc_audience = "zcode"\napi_oidc_jwks_file = "%s"\n' "$jwksdoctorhome/jwks.json" > "$jwksdoctorhome/.zcode/config.toml"
check "enterprise doctor fails writable OIDC JWKS file" \
  bash -c "out=\$(env HOME='$jwksdoctorhome' XDG_CONFIG_HOME='$jwksdoctorhome/.config' '$BIN' doctor enterprise --json 2>/dev/null || true); echo \"\$out\" | grep -q '\"id\":\"api_oidc_jwks_file_permissions\",\"status\":\"fail\"'"

jwkscachehome="$tmp/jwkscachehome"
mkdir -p "$jwkscachehome/.zcode/cache"
printf '{"keys":[]}\n' > "$jwkscachehome/.zcode/cache/api-oidc-jwks.json"
printf '{"schema_version":1,"url":"https://idp.example/jwks","fetched_at":1,"ttl_seconds":3600,"key_count":0}\n' > "$jwkscachehome/.zcode/cache/api-oidc-jwks.json.meta.json"
chmod 0600 "$jwkscachehome/.zcode/cache/api-oidc-jwks.json"
chmod 0666 "$jwkscachehome/.zcode/cache/api-oidc-jwks.json.meta.json"
printf 'api_auth_required = true\napi_oidc_issuer = "https://idp.example"\napi_oidc_audience = "zcode"\napi_oidc_jwks_url = "https://idp.example/jwks"\n' > "$jwkscachehome/.zcode/config.toml"
check "enterprise doctor fails writable OIDC JWKS cache metadata" \
  bash -c "out=\$(env HOME='$jwkscachehome' XDG_CONFIG_HOME='$jwkscachehome/.config' '$BIN' doctor enterprise --json 2>/dev/null || true); echo \"\$out\" | grep -q '\"id\":\"api_oidc_jwks_cache_meta_permissions\",\"status\":\"fail\"'"

# Pass-34: numeric parse errors on config values used to surface as
# the bare `error: failed to load config: Overflow` with no hint
# which key was bad or what range it accepts.
numdir="$tmp/numcfg"
mkdir -p "$numdir/.zcode"

printf 'provider_timeout_ms = 99999999999\n' > "$numdir/.zcode/config.toml"
check "numeric overflow names key + range" \
  usage_err_has "config error: \`provider_timeout_ms = 99999999999\` is out of range" env HOME="$numdir" "$BIN" config show

printf 'provider_retry_count = not-a-number\n' > "$numdir/.zcode/config.toml"
check "non-numeric value names key" \
  usage_err_has "config error: \`provider_retry_count = not-a-number\` is not a valid non-negative integer" env HOME="$numdir" "$BIN" config show

printf 'provider_retry_count = -1\n' > "$numdir/.zcode/config.toml"
check "negative integer rejected with range hint" \
  usage_err_has "config error: \`provider_retry_count = -1\` is out of range" env HOME="$numdir" "$BIN" config show

# Pass-35: config file > 1 MiB used to surface as a bare
# "FileTooBig" error. Now names the file + limit and suppresses
# the generic "delete the file" hint (which was dangerous advice).
bigdir="$tmp/bigcfg"
mkdir -p "$bigdir/.zcode"
head -c 1100000 /dev/urandom | base64 | head -1 > "$bigdir/.zcode/config.toml"
check "oversized config names file + 1 MiB limit" \
  usage_err_has "exceeds the 1 MiB config size limit" env HOME="$bigdir" "$BIN" config show
check "oversized config does NOT suggest deleting the file" \
  bash -c "out=\$(env HOME='$bigdir' '$BIN' config show 2>&1 1>/dev/null); ! echo \"\$out\" | grep -q 'Delete the file'"
check "oversized config exits 2" \
  exit_code_is 2 env HOME="$bigdir" "$BIN" config show

# Pass-36: corrupt MCP registry used to leak
# `error: SyntaxError (provider=..., model=...)` through the agent
# runtime envelope. Now reports cleanly at the mcp-list level.
badmcpdir="$tmp/badmcp"
mkdir -p "$badmcpdir/.zcode/mcp"
echo 'this is not valid json' > "$badmcpdir/.zcode/mcp/servers.json"
check "corrupt mcp registry: clean targeted error" \
  usage_err_has "error: mcp: registry file is not valid JSON" env HOME="$badmcpdir" "$BIN" mcp list
check "corrupt mcp registry exits 1" \
  exit_code_is 1 env HOME="$badmcpdir" "$BIN" mcp list

# Config file with 000 mode: generic "Delete the file to start
# fresh" hint used to be shown, which was actively dangerous --
# the file is the user's REAL config, just unreadable.
permdir="$tmp/permcfg"
mkdir -p "$permdir/.zcode"
echo 'default_model = "ok"' > "$permdir/.zcode/config.toml"
chmod 000 "$permdir/.zcode/config.toml"
check "unreadable config: targeted permission-denied message" \
  usage_err_has "permission denied reading config file" env HOME="$permdir" "$BIN" config show
check "unreadable config does NOT suggest deleting the file" \
  bash -c "out=\$(env HOME='$permdir' '$BIN' config show 2>&1 1>/dev/null); ! echo \"\$out\" | grep -q 'Delete the file'"
chmod 644 "$permdir/.zcode/config.toml"

# Pass-37: corrupt trust store used to leak
# `SyntaxError (provider=..., model=...)` through the agent-runtime
# envelope. Now reports cleanly and exits 1.
bttdir="$tmp/badtrust"
mkdir -p "$bttdir/.zcode/trust"
echo 'not json at all' > "$bttdir/.zcode/trust/repos.json"
check "corrupt trust store: clean targeted error" \
  usage_err_has "error: trust: trust store is not valid JSON" env HOME="$bttdir" "$BIN" trust status
check "corrupt trust store exits 1" \
  exit_code_is 1 env HOME="$bttdir" "$BIN" trust status

# Pass-38: corrupt marketplace-policy.json and hooks.json used to
# leak `SyntaxError (provider=..., model=...)` (when they triggered
# at all) or silently return empty lists. Both now fail loudly via
# parseRegistryJson in core/security.zig.
bsecdir="$tmp/badsec"
mkdir -p "$bsecdir/.zcode/trust"
echo 'not json' > "$bsecdir/.zcode/trust/marketplace-policy.json"
check "corrupt marketplace-policy.json: clean targeted error" \
  usage_err_has "error: trust marketplace: registry file is not valid JSON" env HOME="$bsecdir" "$BIN" trust marketplace
check "corrupt marketplace-policy.json exits 1" \
  exit_code_is 1 env HOME="$bsecdir" "$BIN" trust marketplace

# Pass-39: corrupt agent JSON definition used to leak
# `SyntaxError (provider=..., model=...)` through the agent-runtime
# envelope on `zcode agents list`.
badagdir="$tmp/badag"
mkdir -p "$badagdir/.zcode/agents"
echo 'not valid json' > "$badagdir/.zcode/agents/broken.json"
check "corrupt agent JSON: clean targeted error" \
  usage_err_has "error: agents: invalid JSON in agent definition" env HOME="$badagdir" "$BIN" agents list
check "corrupt agent JSON exits 1" \
  exit_code_is 1 env HOME="$badagdir" "$BIN" agents list

# Pass-40: corrupt plugin manifest used to leak the same
# SyntaxError envelope on `zcode plugins list`.
badpldir="$tmp/badpl"
mkdir -p "$badpldir/.zcode/plugins/broken"
echo 'not json' > "$badpldir/.zcode/plugins/broken/plugin.json"
check "corrupt plugin manifest: clean targeted error" \
  usage_err_has "error: plugins: invalid JSON in plugin manifest" env HOME="$badpldir" "$BIN" plugins list
check "corrupt plugin manifest exits 1" \
  exit_code_is 1 env HOME="$badpldir" "$BIN" plugins list

# Pass-41: `mcp add` on an already-registered server used to write
# "already exists" to stdout and exit 0, so CI scripts could not
# detect the conflict. Now writes to stderr and exits 1.
dupmcpdir="$tmp/dupmcp"
mkdir -p "$dupmcpdir/.zcode/mcp"
cat > "$dupmcpdir/.zcode/mcp/servers.json" <<'EOF'
[{"name":"dup-srv","transport":"echo hi"}]
EOF
check "mcp add duplicate: targeted stderr error" \
  usage_err_has "error: mcp add: server 'dup-srv' is already registered" env HOME="$dupmcpdir" "$BIN" mcp add dup-srv "something-else"
check "mcp add duplicate exits 1" \
  exit_code_is 1 env HOME="$dupmcpdir" "$BIN" mcp add dup-srv "something-else"
check "mcp add duplicate does NOT write banner to stdout" \
  bash -c "[ -z \"\$(env HOME='$dupmcpdir' '$BIN' mcp add dup-srv 'x' 2>/dev/null)\" ]"

# Pass-42: HOME=/dev/null (common container misconfig) used to leak
# `NotDir` with the dangerous "Delete the file" hint. XDG_CONFIG_HOME
# wins over HOME if set, so unset it here to force the HOME path.
check "HOME=/dev/null: clean NotDir message" \
  usage_err_has "a path component is not a directory" env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME HOME=/dev/null "$BIN" policy show
check "HOME=/dev/null does NOT suggest deleting the file" \
  bash -c "out=\$(env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME HOME=/dev/null '$BIN' policy show 2>&1 1>/dev/null); ! echo \"\$out\" | grep -q 'Delete the file'"
check "HOME=/dev/null exits 2" \
  exit_code_is 2 env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME HOME=/dev/null "$BIN" policy show

# Pass-43: numeric config errors (Overflow/InvalidCharacter)
# emitted their targeted line AND the generic 3-hint fallback
# including the dangerous "Delete the file" advice. Now exits
# silently after the targeted line.
numerr_dir="$tmp/numerr"
mkdir -p "$numerr_dir/.zcode"
echo 'provider_timeout_ms = 99999999999' > "$numerr_dir/.zcode/config.toml"
check "numeric overflow: does NOT suggest deleting the file" \
  bash -c "out=\$(env HOME='$numerr_dir' '$BIN' policy show 2>&1 1>/dev/null); ! echo \"\$out\" | grep -q 'Delete the file'"

echo 'provider_retry_count = not-a-number' > "$numerr_dir/.zcode/config.toml"
check "non-numeric: does NOT suggest deleting the file" \
  bash -c "out=\$(env HOME='$numerr_dir' '$BIN' policy show 2>&1 1>/dev/null); ! echo \"\$out\" | grep -q 'Delete the file'"

# Pass-44: --agent <bogus-name> used to silently proceed without
# activating the requested agent; user thought it was active when
# it wasn't. Now exits 2 with an actionable message.
check "--agent <bogus>: clean agent-not-found error" \
  usage_err_has "error: agent not found: zzzz-nonexistent" "$BIN" --agent zzzz-nonexistent run "hi"
check "--agent <bogus> exits 2" \
  exit_code_is 2 "$BIN" --agent zzzz-nonexistent run "hi"

# Pass-45: --output-style <bogus> silently fell back to default
# inside prompt builder, so the operator's requested style was
# never applied.
check "--output-style <bogus>: clean unknown-style error" \
  usage_err_has "error: unknown output style 'zzzz-bogus'" "$BIN" --output-style zzzz-bogus run "hi"
check "--output-style <bogus> exits 2" \
  exit_code_is 2 "$BIN" --output-style zzzz-bogus run "hi"

# Pass-46: --preprocessor-provider <bogus> used to warn-log
# "UnsupportedProvider" at runtime and continue WITHOUT the
# explicitly-requested preprocessor feature.
check "--preprocessor-provider <bogus>: clean error with valid set" \
  usage_err_has "error: invalid --preprocessor-provider 'zzzz'. Expected one of" "$BIN" --preprocessor --preprocessor-provider zzzz --preprocessor-model any config show
check "--preprocessor-provider <bogus> exits 2" \
  exit_code_is 2 "$BIN" --preprocessor --preprocessor-provider zzzz --preprocessor-model any config show

# Pass-47: --log-level was case-insensitive but --approval-mode /
# --sandbox / -p were strictly case-sensitive. Now consistent:
# all enum-style flags accept case-insensitive input and
# canonicalize to lowercase before downstream comparisons run.
check "--approval-mode uppercase accepted and normalized" \
  bash -c "out=\$('$BIN' --approval-mode STRICT config show 2>/dev/null); echo \"\$out\" | grep -q 'approval_mode = \"strict\"'"
check "--sandbox uppercase accepted and normalized" \
  bash -c "out=\$('$BIN' --sandbox READ-ONLY config show 2>/dev/null); echo \"\$out\" | grep -q 'sandbox = \"read-only\"'"
check "-p uppercase provider accepted and normalized" \
  bash -c "out=\$('$BIN' -p OPENAI config show 2>/dev/null); echo \"\$out\" | grep -q 'default_provider = \"openai\"'"

# Pass-48: same normalization applied to config.toml values (pass 47
# only covered the CLI override path), and the ui_density error
# message was listing WRONG valid values ("comfortable, cozy,
# compact" instead of the actual "full, clean").
uctomldir="$tmp/uctoml"
mkdir -p "$uctomldir/.zcode"
cat > "$uctomldir/.zcode/config.toml" <<'EOF'
sandbox = "NO-NETWORK"
approval_mode = "MANUAL"
default_provider = "DEEPSEEK"
EOF
check "config.toml uppercase sandbox normalizes" \
  bash -c "out=\$(env HOME='$uctomldir' '$BIN' config show 2>/dev/null); echo \"\$out\" | grep -q 'sandbox = \"no-network\"'"
check "config.toml uppercase approval_mode normalizes" \
  bash -c "out=\$(env HOME='$uctomldir' '$BIN' config show 2>/dev/null); echo \"\$out\" | grep -q 'approval_mode = \"manual\"'"
check "config.toml uppercase default_provider normalizes" \
  bash -c "out=\$(env HOME='$uctomldir' '$BIN' config show 2>/dev/null); echo \"\$out\" | grep -q 'default_provider = \"deepseek\"'"

uddir="$tmp/uderr"
mkdir -p "$uddir/.zcode"
printf 'ui_density = "bogus"\n' > "$uddir/.zcode/config.toml"
check "ui_density error lists the actual accepted set (full, clean)" \
  usage_err_has "Expected one of: full, clean" env HOME="$uddir" "$BIN" config show

# Pass-49: --append-system-prompt used to accept arbitrarily large
# inline values, bypassing the per-file cap that the file variant
# already enforced. Now capped at 64 KiB.
big_prompt=$(python3 -c "print('x' * 70000)" 2>/dev/null || /usr/bin/python -c "print 'x' * 70000")
check "--append-system-prompt rejects >64 KiB inline value" \
  usage_err_has "exceeds the 64 KiB inline cap" "$BIN" --append-system-prompt "$big_prompt" config show
check "--append-system-prompt >64 KiB exits 2" \
  exit_code_is 2 "$BIN" --append-system-prompt "$big_prompt" config show

# Pass-50: identifier-style flag values used to accept any byte
# including newlines and ANSI escapes, which corrupted log output
# and could smuggle secondary lines into tsv/jsonl log sinks.
check "--model rejects embedded newline" \
  usage_err_has "value contains a control character" bash -c "'$BIN' --model \$'evil\\nhack' config show"
check "--model rejects ANSI escape" \
  usage_err_has "value contains a control character" bash -c "'$BIN' --model \$'evil\\x1b[31m' config show"
check "--sandbox rejects embedded control bytes" \
  usage_err_has "value contains a control character" bash -c "'$BIN' --sandbox \$'read-only\\n' config show"
check "--model with control byte exits 2" \
  exit_code_is 2 bash -c "'$BIN' --model \$'evil\\nhack' config show"

# Pass-51: config.toml values used to accept control bytes
# silently -- an ESC (0x1B) would get stored in default_model and
# could leak into log output later. Now rejected with a targeted
# warning; the default falls through so the tool stays usable.
ctlcfg="$tmp/ctlcfg"
mkdir -p "$ctlcfg/.zcode"
printf 'default_model = "evil\x1bhack"\n' > "$ctlcfg/.zcode/config.toml"
check "config.toml value with ESC byte emits targeted warning" \
  usage_err_has "value contains a control byte (0x1b" env HOME="$ctlcfg" "$BIN" config show
check "config.toml value with ESC byte falls back to default" \
  bash -c "out=\$(env HOME='$ctlcfg' '$BIN' config show 2>/dev/null); echo \"\$out\" | grep -q 'default_model = \"claude-opus'"

# Pass-52: hostile env vars with embedded newlines / ANSI escapes
# used to break the two-column `--list-env` format or smuggle
# terminal-control bytes into the operator's stdout. Now escaped
# as \xHH.
check "--list-env escapes newline in OLLAMA_BASE_URL" \
  bash -c "out=\$(env OLLAMA_BASE_URL=\$'http://x\\nevil' '$BIN' --list-env 2>/dev/null); echo \"\$out\" | grep -q 'OLLAMA_BASE_URL.*http://x\\\\x0aevil'"
check "--list-env escapes ESC in env value" \
  bash -c "out=\$(env XDG_DATA_HOME=\$'dir\\x1b[31m' '$BIN' --list-env 2>/dev/null); echo \"\$out\" | grep -q 'XDG_DATA_HOME.*dir\\\\x1b\\[31m'"
check "--list-env preserves clean values unchanged" \
  bash -c "out=\$(env OLLAMA_BASE_URL='http://127.0.0.1:11434' '$BIN' --list-env 2>/dev/null); echo \"\$out\" | grep -q 'http://127.0.0.1:11434'"

# Pass-53: an MCP server name with an embedded newline (someone
# hand-edited servers.json) used to print as TWO lines in
# `mcp list`, breaking the TSV layout and faking a second entry.
mcpsanedir="$tmp/mcpsane"
mkdir -p "$mcpsanedir/.zcode/mcp"
cat > "$mcpsanedir/.zcode/mcp/servers.json" <<'EOF'
[{"name":"line1\nline2","transport":"echo hi"}]
EOF
check "mcp list escapes newline in stored server name" \
  bash -c "out=\$(env HOME='$mcpsanedir' '$BIN' mcp list 2>/dev/null); echo \"\$out\" | grep -q 'line1\\\\x0aline2'"
check "mcp list does NOT split the row across multiple lines" \
  bash -c "out=\$(env HOME='$mcpsanedir' '$BIN' mcp list 2>/dev/null); ! echo \"\$out\" | grep -qE '^line2'"

# Pass-54: trust marketplace + agents show display paths used to
# render hand-edited JSON values verbatim, so an embedded newline
# in a marketplace allow-prefix or an agent description broke the
# key=value layout. Now sanitized via display_safe.
mktrustdir="$tmp/mktrust"
mkdir -p "$mktrustdir/.zcode/trust"
cat > "$mktrustdir/.zcode/trust/marketplace-policy.json" <<'EOF'
{"allow":["good","line1\nline2"],"block":[]}
EOF
check "trust marketplace escapes newline in allow prefix" \
  bash -c "out=\$(env HOME='$mktrustdir' '$BIN' trust marketplace 2>/dev/null); echo \"\$out\" | grep -q 'line1\\\\x0aline2'"
check "trust marketplace does NOT split the row" \
  bash -c "out=\$(env HOME='$mktrustdir' '$BIN' trust marketplace 2>/dev/null); ! echo \"\$out\" | grep -qE '^line2$'"

agshowdir="$tmp/agshow"
mkdir -p "$agshowdir/.zcode/agents"
cat > "$agshowdir/.zcode/agents/sneaky.json" <<'EOF'
{"name":"sneaky","description":"line1\nline2","system_prompt":"x"}
EOF
check "agents show escapes newline in description" \
  bash -c "out=\$(env HOME='$agshowdir' '$BIN' agents show sneaky 2>/dev/null); echo \"\$out\" | grep -q 'description=line1\\\\x0aline2'"

# Pass-55: plugins show + plugins list rendered manifest fields
# verbatim, so a newline in `description` corrupted the YAML-style
# detail block ("description: line1" then a bare "line2" row).
plugin_dir="$tmp/snplugin"
mkdir -p "$plugin_dir/.zcode/plugins/sneaky"
cat > "$plugin_dir/.zcode/plugins/sneaky/plugin.json" <<'EOF'
{"name":"sneaky","version":"0.1.0","description":"line1\nline2","entrypoint":"x.sh"}
EOF
check "plugins show escapes newline in description" \
  bash -c "out=\$(env HOME='$plugin_dir' '$BIN' plugins show sneaky 2>/dev/null); echo \"\$out\" | grep -q 'description: line1\\\\x0aline2'"
check "plugins show does NOT split the description row" \
  bash -c "out=\$(env HOME='$plugin_dir' '$BIN' plugins show sneaky 2>/dev/null); ! echo \"\$out\" | grep -qE '^line2$'"

# Pass-57: session list rendered the user-supplied label sidecar
# verbatim, so a hand-edited sidecar with a newline corrupted the
# TSV layout and faked an extra row. Now sanitized via display_safe.
sslblbase="$tmp/sslbl"
mkdir -p "$sslblbase/.zcode/sessions"
sid="1234567890-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
cat > "$sslblbase/.zcode/sessions/$sid.jsonl" <<'EOF'
{"role":"user","content":"hi","timestamp":1}
EOF
printf 'evil\nlabel' > "$sslblbase/.zcode/sessions/$sid.label"
check "session list escapes newline in user label" \
  bash -c "out=\$(env HOME='$sslblbase' '$BIN' session list 2>/dev/null); echo \"\$out\" | grep -q 'evil\\\\x0alabel'"
check "session list does NOT split the row on hostile label" \
  bash -c "out=\$(env HOME='$sslblbase' '$BIN' session list 2>/dev/null); ! echo \"\$out\" | grep -qE '^label\\b'"

# Pass-58: skills + commands renderers fed markdown-frontmatter
# description through to display verbatim, so a real ESC byte
# in the description corrupted the list/show header.
sktest="$tmp/sktest"
mkdir -p "$sktest/.zcode/skills/sneaky"
printf -- '---\ndescription: red\x1bevil\n---\nbody\n' > "$sktest/.zcode/skills/sneaky/SKILL.md"
check "skills list escapes ESC in description" \
  bash -c "out=\$(env HOME='$sktest' '$BIN' skills list 2>/dev/null); echo \"\$out\" | grep -q 'red\\\\x1bevil'"

cmtest="$tmp/cmtest"
mkdir -p "$cmtest/.zcode/commands"
printf -- '---\ndescription: red\x1bevil\n---\nbody\n' > "$cmtest/.zcode/commands/sneaky.md"
check "commands list escapes ESC in description" \
  bash -c "out=\$(env HOME='$cmtest' '$BIN' commands list 2>/dev/null); echo \"\$out\" | grep -q 'red\\\\x1bevil'"

# Pass-61: marketplace sources renderer fed source.name / url /
# cache_path verbatim. A hand-edited sources.json with a newline
# in `name` faked a second source row.
mptest="$tmp/mptest"
mkdir -p "$mptest/.zcode/marketplace"
cat > "$mptest/.zcode/marketplace/sources.json" <<'EOF'
[{"name":"line1\nline2","url":"https://example.com/x.json","sha256":"abc"}]
EOF
check "marketplace sources escapes newline in source name" \
  bash -c "out=\$(env HOME='$mptest' '$BIN' marketplace sources 2>/dev/null); echo \"\$out\" | grep -q 'line1\\\\x0aline2'"

# --- summary ---------------------------------------------------------
printf '\n==> %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
