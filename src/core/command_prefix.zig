//! Static command-prefix extraction (bash-shell-03).
//!
//! Computes a stable, reusable command prefix from a concrete command
//! (e.g. `git -C /repo status --short` -> `git status`) so the approval
//! flow can suggest a reusable allow-rule instead of only "deny this
//! exact command." This is the missing half of zcode's permission UX.
//!
//! We use a native static heuristic (first word + a small known-
//! subcommand table + per-command depth overrides), NOT an LLM extractor
//! and NOT the external @withfig/autocomplete fig-spec dependency. The
//! acceptance bar is "suggests a useful, never-overbroad prefix," not
//! byte-parity with the reference's fig-spec walk.
//!
//! Reference behavior ported here:
//!   - specPrefix.ts:88-209 (buildPrefix / calculateDepth: walk args,
//!     skip flags and their values, find the first known subcommand,
//!     apply DEPTH_RULES).
//!   - specPrefix.ts:21-34 (DEPTH_RULES: per-command depth overrides).
//!   - prefix.ts:28-44 (DANGEROUS_SHELL_PREFIXES: never accept bare
//!     `sh`, `bash`, `zsh`, ..., or bare `git`).
//!   - bash/prefix.ts:135-204 (getCompoundCommandPrefixesStatic +
//!     longestCommonPrefix: per-subcommand prefixes collapsed via
//!     word-aligned longest common prefix).
//!
//! This is a deep, pure module: pure over `(allocator, command)`, no IO,
//! no env reads, no `rt.io`. It imports `bash_ast` only for the
//! quote-aware operator split (compound segmentation).

const std = @import("std");
const Allocator = std.mem.Allocator;
const bash_ast = @import("bash_ast.zig");

/// Shell executables that must never be accepted as bare prefixes.
/// Allowing e.g. `bash:*` would let any command through, defeating the
/// permission system. Ported from prefix.ts:28-44 (Unix shells +
/// Windows equivalents).
const DANGEROUS_SHELL_PREFIXES = [_][]const u8{
    "sh",
    "bash",
    "zsh",
    "fish",
    "csh",
    "tcsh",
    "ksh",
    "dash",
    "cmd",
    "cmd.exe",
    "powershell",
    "powershell.exe",
    "pwsh",
    "pwsh.exe",
    "bash.exe",
};

/// Wrapper commands whose first real argument is the command we actually
/// want to extract a prefix from. We strip these (and any leading
/// env-assignments) before resolving the real command word. Mirrors the
/// reference's WRAPPER_COMMANDS / commandWordAfterWrappers concept; kept
/// local so this module stays pure (no import of bash_security).
const WRAPPER_COMMANDS = [_][]const u8{
    "sudo",
    "time",
    "nice",
    "env",
    "nohup",
    "stdbuf",
};

/// Per-command depth overrides. Ports specPrefix.ts:21-34. The depth is
/// the number of leading words (including the command itself) the prefix
/// may include. A command with a known subcommand defaults to depth 2;
/// these override that for deeper subcommand trees.
const DepthRule = struct { key: []const u8, depth: usize };
const DEPTH_RULES = [_]DepthRule{
    .{ .key = "rg", .depth = 2 },
    .{ .key = "pre-commit", .depth = 2 },
    .{ .key = "gcloud", .depth = 4 },
    .{ .key = "gcloud compute", .depth = 6 },
    .{ .key = "gcloud beta", .depth = 6 },
    .{ .key = "aws", .depth = 4 },
    .{ .key = "az", .depth = 4 },
    .{ .key = "kubectl", .depth = 3 },
    .{ .key = "docker", .depth = 3 },
    .{ .key = "dotnet", .depth = 3 },
    .{ .key = "git push", .depth = 2 },
};

/// A known-subcommand table for the common multi-word CLIs that the
/// reference depends on fig-spec for. Deliberately small and curated; do
/// NOT try to replicate the entire fig-spec. If a command's first
/// non-flag arg is in its list, we treat it as a subcommand and build
/// `command subcommand` (up to the depth rule).
const SubcommandSet = struct { command: []const u8, subcommands: []const []const u8 };
const KNOWN_SUBCOMMANDS = [_]SubcommandSet{
    .{ .command = "git", .subcommands = &.{
        "status",    "log",     "diff",         "show",        "fetch",    "push",
        "pull",      "commit",  "add",          "checkout",    "branch",   "merge",
        "rebase",    "stash",   "tag",          "remote",      "clone",    "init",
        "reset",     "restore", "switch",       "cherry-pick", "worktree", "grep",
        "blame",     "config",  "clean",        "revert",      "describe", "bisect",
        "submodule", "apply",   "format-patch", "rev-parse",   "ls-files", "show-ref",
    } },
    .{ .command = "npm", .subcommands = &.{
        "run",    "install",   "ci",   "test", "start", "build", "publish",
        "update", "uninstall", "exec", "init", "audit", "link",
    } },
    .{ .command = "pnpm", .subcommands = &.{
        "run",     "install", "add",  "remove", "test", "start", "build",
        "publish", "update",  "exec", "dlx",
    } },
    .{ .command = "yarn", .subcommands = &.{
        "run",     "install", "add", "remove", "test", "start", "build",
        "publish", "upgrade", "dlx",
    } },
    .{ .command = "cargo", .subcommands = &.{
        "build",   "test",    "run",    "check", "fmt",   "clippy", "doc",
        "publish", "install", "update", "add",   "bench", "new",    "init",
    } },
    .{ .command = "docker", .subcommands = &.{
        "run", "build", "ps",    "exec", "pull",    "push",    "images", "rm",
        "rmi", "stop",  "start", "logs", "compose", "inspect", "tag",
    } },
    .{ .command = "kubectl", .subcommands = &.{
        "get",  "describe", "apply", "delete", "create",       "logs",    "exec",
        "edit", "rollout",  "scale", "config", "port-forward", "explain",
    } },
    .{ .command = "zig", .subcommands = &.{
        "build",     "test", "fmt",     "run",  "cc", "c++", "translate-c",
        "ast-check", "env",  "version", "init",
    } },
    .{ .command = "go", .subcommands = &.{
        "build",    "test", "run",  "vet",  "get", "install", "mod", "fmt",
        "generate", "tool", "work", "list",
    } },
};

/// Value-taking flags by command. When one of these flags appears, the
/// next token is its value and must be skipped (not treated as a
/// subcommand). Heuristic equivalent of the reference's spec.options
/// `args` lookup (specPrefix.ts:50-68).
const ValueFlagSet = struct { command: []const u8, flags: []const []const u8 };
const VALUE_FLAGS = [_]ValueFlagSet{
    .{ .command = "git", .flags = &.{ "-C", "-c", "--git-dir", "--work-tree", "--namespace" } },
    .{ .command = "docker", .flags = &.{"--context"} },
    .{ .command = "kubectl", .flags = &.{ "-n", "--namespace", "--context", "--kubeconfig" } },
};

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn isDangerousShellPrefix(word: []const u8) bool {
    for (DANGEROUS_SHELL_PREFIXES) |p| {
        if (eqlIgnoreCase(word, p)) return true;
    }
    return false;
}

fn isWrapper(word: []const u8) bool {
    for (WRAPPER_COMMANDS) |w| {
        if (std.mem.eql(u8, word, w)) return true;
    }
    return false;
}

fn isEnvAssignment(word: []const u8) bool {
    // FOO=bar : a `=` not at position 0, with a leading identifier.
    const eq = std.mem.indexOfScalar(u8, word, '=') orelse return false;
    if (eq == 0) return false;
    var i: usize = 0;
    while (i < eq) : (i += 1) {
        const c = word[i];
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

fn knownSubcommands(command: []const u8) ?[]const []const u8 {
    for (KNOWN_SUBCOMMANDS) |set| {
        if (eqlIgnoreCase(command, set.command)) return set.subcommands;
    }
    return null;
}

fn isKnownSubcommand(command: []const u8, arg: []const u8) bool {
    const subs = knownSubcommands(command) orelse return false;
    for (subs) |s| {
        if (eqlIgnoreCase(arg, s)) return true;
    }
    return false;
}

fn isValueFlag(command: []const u8, flag: []const u8) bool {
    for (VALUE_FLAGS) |set| {
        if (!eqlIgnoreCase(command, set.command)) continue;
        for (set.flags) |f| {
            if (std.mem.eql(u8, flag, f)) return true;
        }
    }
    return false;
}

/// Depth override for a command + first-subcommand pair. Mirrors
/// calculateDepth's DEPTH_RULES lookup (specPrefix.ts:147-151): try the
/// `command subcommand` key first, then the bare command key.
fn depthRule(command: []const u8, first_sub: ?[]const u8) ?usize {
    if (first_sub) |sub| {
        var buf: [128]u8 = undefined;
        if (command.len + 1 + sub.len <= buf.len) {
            _ = std.ascii.lowerString(buf[0..command.len], command);
            buf[command.len] = ' ';
            _ = std.ascii.lowerString(buf[command.len + 1 .. command.len + 1 + sub.len], sub);
            const key = buf[0 .. command.len + 1 + sub.len];
            for (DEPTH_RULES) |r| {
                if (std.mem.eql(u8, key, r.key)) return r.depth;
            }
        }
    }
    for (DEPTH_RULES) |r| {
        if (eqlIgnoreCase(command, r.key)) return r.depth;
    }
    return null;
}

// --- quote-aware tokenizer (local, pure) ----------------------------------

const Token = struct {
    raw: []const u8,
    next: usize,
};

/// Pull the next whitespace-delimited shell word starting at or after
/// `start`, honouring single/double quotes and backslash escapes.
/// Returns the RAW token (quotes still attached); use `normalize` to
/// strip surrounding quotes.
fn nextWord(command: []const u8, start: usize) ?Token {
    var i = start;
    while (i < command.len and std.ascii.isWhitespace(command[i])) : (i += 1) {}
    if (i >= command.len) return null;
    const begin = i;
    var escaped = false;
    var in_single = false;
    var in_double = false;
    while (i < command.len) : (i += 1) {
        const c = command[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\' and !in_single) {
            escaped = true;
            continue;
        }
        if (c == '\'' and !in_double) {
            in_single = !in_single;
            continue;
        }
        if (c == '"' and !in_single) {
            in_double = !in_double;
            continue;
        }
        if (!in_single and !in_double and std.ascii.isWhitespace(c)) break;
    }
    return .{ .raw = command[begin..i], .next = i };
}

/// Strip a single pair of matching surrounding quotes from a raw token.
fn normalize(raw: []const u8) []const u8 {
    if (raw.len >= 2 and ((raw[0] == '"' and raw[raw.len - 1] == '"') or (raw[0] == '\'' and raw[raw.len - 1] == '\''))) {
        return raw[1 .. raw.len - 1];
    }
    return raw;
}

/// Resolved command word: the first real command after skipping leading
/// env-assignments and wrapper commands, plus the index where its args
/// begin.
const Resolved = struct {
    command: []const u8,
    rest_index: usize,
};

fn resolveCommand(command: []const u8) ?Resolved {
    var cursor: usize = 0;
    while (nextWord(command, cursor)) |tok| {
        cursor = tok.next;
        const word = normalize(tok.raw);
        if (word.len == 0) continue;
        if (isEnvAssignment(word)) continue;
        if (!isWrapper(word)) {
            return .{ .command = word, .rest_index = cursor };
        }
        // `env` may be followed by more env-assignments before the real
        // command; skip them.
        if (std.mem.eql(u8, word, "env")) {
            while (nextWord(command, cursor)) |peek| {
                if (!isEnvAssignment(normalize(peek.raw))) break;
                cursor = peek.next;
            }
        }
    }
    return null;
}

// --- prefix extraction -----------------------------------------------------

/// Extract a reusable prefix from a single (non-compound) command.
/// Returns an owned slice or null when no useful, safe prefix exists.
///
/// Examples:
///   `git -C /repo status --short` -> "git status"
///   `git status`                  -> "git status"
///   `git`                         -> null  (bare git rejected)
///   `bash -c 'rm -rf /'`          -> null  (dangerous shell prefix)
///   `npm run test`                -> "npm run"
pub fn extract(allocator: Allocator, command: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) return null;

    const resolved = resolveCommand(trimmed) orelse return null;
    const cmd = resolved.command;
    if (cmd.len == 0) return null;

    // Never accept a bare shell as a prefix.
    if (isDangerousShellPrefix(cmd)) return null;

    const has_subs = knownSubcommands(cmd) != null;

    // First pass: find the first known subcommand (skipping flags and
    // their values) so we can choose the right depth rule.
    const first_sub = findFirstSubcommand(trimmed, cmd, resolved.rest_index);

    // Bare `git` (or any known-subcommand CLI invoked with no subcommand)
    // is rejected: an unbounded `git:*`-style rule is too broad.
    if (has_subs and first_sub == null) return null;

    // Depth: an explicit rule wins; else 2 when a subcommand exists, else 1.
    const max_depth: usize = depthRule(cmd, first_sub) orelse
        (if (has_subs) @as(usize, 2) else @as(usize, 1));

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    try parts.append(allocator, cmd);

    var found_sub = false;
    var cursor = resolved.rest_index;
    while (parts.items.len < max_depth) {
        const tok = nextWord(trimmed, cursor) orelse break;
        cursor = tok.next;
        const word = normalize(tok.raw);
        if (word.len == 0) continue;

        if (std.mem.startsWith(u8, word, "-")) {
            // python -c / python3 -c terminates the prefix.
            if (std.mem.eql(u8, word, "-c") and
                (eqlIgnoreCase(cmd, "python") or eqlIgnoreCase(cmd, "python3")))
            {
                break;
            }
            // For commands with subcommands, skip global flags (and a
            // value if the flag takes one) until we find the subcommand.
            if (has_subs and !found_sub) {
                if (isValueFlag(cmd, word)) {
                    // consume the flag's value token, if any
                    if (nextWord(trimmed, cursor)) |val| {
                        // Only consume if it is not itself a subcommand.
                        const vw = normalize(val.raw);
                        if (!isKnownSubcommand(cmd, vw)) cursor = val.next;
                    }
                }
                continue;
            }
            // Otherwise a flag ends the prefix.
            break;
        }

        // A non-flag word.
        if (has_subs and !found_sub) {
            if (isKnownSubcommand(cmd, word)) {
                found_sub = true;
                try parts.append(allocator, word);
                continue;
            }
            // Non-flag, non-subcommand before any subcommand: this is a
            // positional value (e.g. `git -C /repo` already consumed the
            // path, but a stray path here) -> stop. Building further would
            // bake a transient value into the rule.
            break;
        }

        try parts.append(allocator, word);
    }

    // Build the joined prefix.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (parts.items, 0..) |p, idx| {
        if (idx != 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, p);
    }
    const result = try out.toOwnedSlice(allocator);

    // Validate the result is an actual prefix of the trimmed command
    // (reference guard prefix.ts:303). It may differ in flag ordering for
    // wrapped/env-stripped commands, so we check word-by-word presence in
    // order rather than a raw byte prefix.
    if (!isWordPrefixOf(result, trimmed)) {
        allocator.free(result);
        return null;
    }
    return result;
}

/// True when the resolved command word of `segment` (after stripping
/// leading env-assignments and wrapper commands like `sudo`/`env`) is
/// `cd`. Pure first-word check. Used by the per-segment permission
/// layer to count directory changes and to detect the cd+git bare-repo
/// attack pattern. Reference: bashCommandHelpers.ts:36 (multi-cd count)
/// and :70 (cd+git guard).
pub fn isNormalizedCdCommand(segment: []const u8) bool {
    const resolved = resolveCommand(std.mem.trim(u8, segment, " \t\r\n")) orelse return false;
    return std.mem.eql(u8, resolved.command, "cd");
}

/// True when the resolved command word of `segment` (after wrapper /
/// env-assignment stripping) is `git`. Pure first-word check. Used with
/// `isNormalizedCdCommand` for the cd+git bare-repository guard.
/// Reference: bashCommandHelpers.ts:70.
pub fn isNormalizedGitCommand(segment: []const u8) bool {
    const resolved = resolveCommand(std.mem.trim(u8, segment, " \t\r\n")) orelse return false;
    return std.mem.eql(u8, resolved.command, "git");
}

/// Find the first known subcommand by skipping flags and their values.
/// Mirrors findFirstSubcommand (specPrefix.ts:71-86). Returns a slice
/// into `command`.
fn findFirstSubcommand(command: []const u8, cmd: []const u8, start: usize) ?[]const u8 {
    const has_subs = knownSubcommands(cmd) != null;
    var cursor = start;
    while (nextWord(command, cursor)) |tok| {
        cursor = tok.next;
        const word = normalize(tok.raw);
        if (word.len == 0) continue;
        if (std.mem.startsWith(u8, word, "-")) {
            if (isValueFlag(cmd, word)) {
                if (nextWord(command, cursor)) |val| {
                    const vw = normalize(val.raw);
                    if (!isKnownSubcommand(cmd, vw)) cursor = val.next;
                }
            }
            continue;
        }
        if (!has_subs) return word;
        if (isKnownSubcommand(cmd, word)) return word;
    }
    return null;
}

/// Whether every word of `prefix` appears, in order, among the command's
/// words (gaps allowed, since flags and flag-values are legitimately
/// skipped during extraction, e.g. `git status` is a valid prefix of
/// `git -C /repo status --short`). Mirrors the intent of the reference
/// guard (prefix.ts:303) without rejecting flag-skipped prefixes.
fn isWordPrefixOf(prefix: []const u8, command: []const u8) bool {
    var pit = std.mem.tokenizeScalar(u8, prefix, ' ');
    var cursor: usize = 0;
    while (pit.next()) |pword| {
        var matched = false;
        while (nextWord(command, cursor)) |tok| {
            cursor = tok.next;
            const word = normalize(tok.raw);
            if (word.len == 0) continue;
            if (std.mem.eql(u8, word, pword)) {
                matched = true;
                break;
            }
            // Skip any intervening word (flag, flag value, env-assign,
            // wrapper) and keep looking for this prefix word.
        }
        if (!matched) return false;
    }
    return true;
}

// --- compound extraction ---------------------------------------------------

/// Extract collapsed prefixes from a compound command (split on
/// `&&`/`||`/`;`). Per-segment prefixes are grouped by first word and
/// each group is collapsed via word-aligned longest common prefix.
/// Ports getCompoundCommandPrefixesStatic (bash/prefix.ts:135-175).
///
/// Returns an owned slice of owned slices. Free with `freeCompound`.
///
/// Examples:
///   `git fetch && git worktree list` -> ["git"]   (LCP collapse)
///   `npm run test && npm run lint`    -> ["npm run"]
pub fn extractCompound(allocator: Allocator, command: []const u8) ![][]u8 {
    var analysis = try bash_ast.analyze(allocator, command);
    defer analysis.deinit(allocator);

    const segs = analysis.structure.segments;

    // Single command (no operator split): one prefix or none.
    if (segs.len <= 1) {
        const single = if (segs.len == 1) segs[0] else command;
        if (try extract(allocator, single)) |pfx| {
            const list = try allocator.alloc([]u8, 1);
            list[0] = pfx;
            return list;
        }
        return allocator.alloc([]u8, 0);
    }

    // Collect a prefix per segment (owned).
    var prefixes: std.ArrayList([]u8) = .empty;
    defer {
        for (prefixes.items) |p| allocator.free(p);
        prefixes.deinit(allocator);
    }
    for (segs) |seg| {
        if (try extract(allocator, seg)) |pfx| {
            try prefixes.append(allocator, pfx);
        }
    }
    if (prefixes.items.len == 0) return allocator.alloc([]u8, 0);

    // Group by first word (root command), preserving first-seen order.
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(allocator);
    var groups: std.ArrayList(std.ArrayList([]u8)) = .empty;
    defer {
        for (groups.items) |*g| g.deinit(allocator);
        groups.deinit(allocator);
    }

    for (prefixes.items) |pfx| {
        const root = firstWord(pfx);
        var gi: ?usize = null;
        for (roots.items, 0..) |r, idx| {
            if (std.mem.eql(u8, r, root)) {
                gi = idx;
                break;
            }
        }
        if (gi == null) {
            try roots.append(allocator, root);
            try groups.append(allocator, .empty);
            gi = groups.items.len - 1;
        }
        try groups.items[gi.?].append(allocator, pfx);
    }

    // Collapse each group via word-aligned LCP into owned results.
    var collapsed: std.ArrayList([]u8) = .empty;
    errdefer {
        for (collapsed.items) |c| allocator.free(c);
        collapsed.deinit(allocator);
    }
    for (groups.items) |g| {
        const lcp = try longestCommonPrefix(allocator, g.items);
        try collapsed.append(allocator, lcp);
    }
    return collapsed.toOwnedSlice(allocator);
}

/// Free the slice returned by `extractCompound`.
pub fn freeCompound(allocator: Allocator, prefixes: [][]u8) void {
    for (prefixes) |p| allocator.free(p);
    allocator.free(prefixes);
}

fn firstWord(s: []const u8) []const u8 {
    const idx = std.mem.indexOfScalar(u8, s, ' ') orelse return s;
    return s[0..idx];
}

/// Word-aligned longest common prefix of the strings. Ports
/// longestCommonPrefix (bash/prefix.ts:182-204). Always keeps at least
/// the first word. Returns an owned slice.
fn longestCommonPrefix(allocator: Allocator, strings: []const []u8) ![]u8 {
    if (strings.len == 0) return allocator.alloc(u8, 0);
    if (strings.len == 1) return allocator.dupe(u8, strings[0]);

    const first = strings[0];
    // Words of the first string.
    var first_words: std.ArrayList([]const u8) = .empty;
    defer first_words.deinit(allocator);
    {
        var it = std.mem.tokenizeScalar(u8, first, ' ');
        while (it.next()) |w| try first_words.append(allocator, w);
    }
    var common: usize = first_words.items.len;

    for (strings[1..]) |other| {
        var oit = std.mem.tokenizeScalar(u8, other, ' ');
        var shared: usize = 0;
        while (shared < common) {
            const ow = oit.next() orelse break;
            if (!std.mem.eql(u8, first_words.items[shared], ow)) break;
            shared += 1;
        }
        common = shared;
    }
    if (common < 1) common = 1;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (first_words.items[0..common], 0..) |w, idx| {
        if (idx != 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, w);
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectExtract(command: []const u8, expected: ?[]const u8) !void {
    const got = try extract(testing.allocator, command);
    defer if (got) |g| testing.allocator.free(g);
    if (expected) |e| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(e, got.?);
    } else {
        try testing.expect(got == null);
    }
}

test "extract: git with -C flag and value resolves to git status" {
    try expectExtract("git -C /repo status --short", "git status");
}

test "extract: bare git status" {
    try expectExtract("git status", "git status");
}

test "extract: bare git is rejected" {
    try expectExtract("git", null);
}

test "extract: dangerous shell prefix bash -c is rejected" {
    try expectExtract("bash -c 'rm -rf /'", null);
}

test "extract: sh/zsh/fish bare are rejected" {
    try expectExtract("sh", null);
    try expectExtract("zsh -lc 'echo hi'", null);
    try expectExtract("fish", null);
}

test "extract: npm run collapses to npm run (depth 2)" {
    try expectExtract("npm run test", "npm run");
}

test "extract: git push depth rule keeps it at git push" {
    try expectExtract("git push --force origin main", "git push");
}

test "extract: kubectl depth rule allows three words" {
    // DEPTH_RULES kubectl=3, so the prefix includes the resource word.
    try expectExtract("kubectl get pods -n default", "kubectl get pods");
}

test "extract: docker run with subcommand" {
    try expectExtract("docker build -t img .", "docker build");
}

test "extract: unknown command yields bare command (depth 1)" {
    try expectExtract("ls -la /tmp", "ls");
}

test "extract: env-assignment prefix is stripped" {
    try expectExtract("FOO=bar git status", "git status");
}

test "extract: sudo wrapper is stripped" {
    try expectExtract("sudo git status", "git status");
}

test "extract: empty or whitespace yields null" {
    try expectExtract("", null);
    try expectExtract("   ", null);
}

test "extract: zig build" {
    try expectExtract("zig build -Doptimize=ReleaseFast", "zig build");
}

fn expectCompound(command: []const u8, expected: []const []const u8) !void {
    const got = try extractCompound(testing.allocator, command);
    defer freeCompound(testing.allocator, got);
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| {
        try testing.expectEqualStrings(e, g);
    }
}

test "extractCompound: git fetch && git worktree list collapses to git" {
    try expectCompound("git fetch && git worktree list", &.{"git"});
}

test "extractCompound: npm run test && npm run lint collapses to npm run" {
    try expectCompound("npm run test && npm run lint", &.{"npm run"});
}

test "extractCompound: single command returns single prefix" {
    try expectCompound("git status --short", &.{"git status"});
}

test "extractCompound: mixed roots produce one prefix per root" {
    // git fetch -> "git fetch", ls -> "ls"; two distinct roots, two
    // single-element groups, so each group keeps its full prefix.
    const got = try extractCompound(testing.allocator, "git fetch && ls -la");
    defer freeCompound(testing.allocator, got);
    try testing.expectEqual(@as(usize, 2), got.len);
    // order is first-seen: git group then ls group.
    try testing.expectEqualStrings("git fetch", got[0]);
    try testing.expectEqualStrings("ls", got[1]);
}

test "extractCompound: dangerous-shell segment dropped, others kept" {
    // The `bash -c ...` segment yields no prefix; only `git status` survives.
    try expectCompound("bash -c 'x' && git status", &.{"git status"});
}

test "extractCompound: all-rejected yields empty slice" {
    const got = try extractCompound(testing.allocator, "git && sh");
    defer freeCompound(testing.allocator, got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "longestCommonPrefix: keeps at least first word" {
    var a = [_]u8{ 'g', 'i', 't', ' ', 'f', 'e', 't', 'c', 'h' };
    var b = [_]u8{ 'g', 'i', 't', ' ', 'l', 'o', 'g' };
    const items = [_][]u8{ a[0..], b[0..] };
    const lcp = try longestCommonPrefix(testing.allocator, items[0..]);
    defer testing.allocator.free(lcp);
    try testing.expectEqualStrings("git", lcp);
}

test "no-leak fuzz: run a table of commands through extract/extractCompound" {
    const samples = [_][]const u8{
        "git -C /repo status --short",
        "git status",
        "git",
        "bash -c 'rm -rf /'",
        "npm run test",
        "git push --force origin main",
        "kubectl get pods -n default",
        "docker build -t img .",
        "ls -la /tmp",
        "FOO=bar git status",
        "sudo git status",
        "git fetch && git worktree list",
        "npm run test && npm run lint",
        "git fetch && ls -la",
        "cargo build --release",
        "zig build test",
        "echo 'a;b' | wc -l",
        "",
        "   ",
    };
    for (samples) |cmd| {
        if (try extract(testing.allocator, cmd)) |p| testing.allocator.free(p);
        const comp = try extractCompound(testing.allocator, cmd);
        freeCompound(testing.allocator, comp);
    }
}

test "isNormalizedCdCommand: bare cd and wrapped cd" {
    try testing.expect(isNormalizedCdCommand("cd src"));
    try testing.expect(isNormalizedCdCommand("cd"));
    try testing.expect(isNormalizedCdCommand("  cd /tmp  "));
    try testing.expect(isNormalizedCdCommand("sudo cd /root"));
    try testing.expect(!isNormalizedCdCommand("cdh foo"));
    try testing.expect(!isNormalizedCdCommand("git status"));
    try testing.expect(!isNormalizedCdCommand(""));
}

test "isNormalizedGitCommand: bare git and wrapped git" {
    try testing.expect(isNormalizedGitCommand("git status"));
    try testing.expect(isNormalizedGitCommand("git"));
    try testing.expect(isNormalizedGitCommand("FOO=bar git log"));
    try testing.expect(isNormalizedGitCommand("sudo git push"));
    try testing.expect(!isNormalizedGitCommand("github cli"));
    try testing.expect(!isNormalizedGitCommand("cd src"));
    try testing.expect(!isNormalizedGitCommand(""));
}
