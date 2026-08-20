//! Destructive-command advisory notes (bash-shell-05).
//!
//! Produces a short, human-readable advisory string for reversible-but-risky
//! git/db/infra commands so the approval dialog can warn the user (e.g.
//! "Note: may overwrite remote history"). This is ADVISORY ONLY: it does NOT
//! change risk tier or auto-approval. The risk-elevation path lives separately
//! in bash_security.zig / policy.zig; this module only annotates the dialog.
//!
//! Reference behavior ported here:
//!   - tools/BashTool/destructiveCommandWarning.ts:12-102
//!     (DESTRUCTIVE_PATTERNS, getDestructiveCommandWarning: git reset --hard,
//!     push --force/-f, clean -f, checkout/restore ., stash drop/clear,
//!     branch -D, --no-verify, commit --amend, rm -rf/-f, DROP/TRUNCATE/
//!     DELETE FROM, kubectl delete, terraform destroy).
//!
//! We use simple substring / word-boundary checks (no regex engine), matching
//! the advisory intent rather than the reference regex byte-for-byte. For
//! patterns that need a flag near a verb (e.g. `git push ... --force`) we
//! check that both the verb substring and the flag substring co-occur in the
//! same command -- good enough for an advisory note.

const std = @import("std");
const parse_helpers = @import("parse_helpers.zig");

const contains = parse_helpers.containsIgnoreCase;

/// A pattern entry: the command must contain `needle1`, and (if non-empty)
/// also `needle2`, for the advisory `note` to fire. `word_bounded` makes the
/// match require `needle1` to sit on a word boundary (used for SQL keywords
/// like DELETE so `deleted_files` does not trip it).
const Pattern = struct {
    needle1: []const u8,
    needle2: []const u8 = "",
    note: []const u8,
    word_bounded: bool = false,
};

/// Curated advisory patterns. Order matters only for which note is returned
/// first when several match; the more-specific / higher-blast-radius entries
/// come first. All note strings use plain hyphens (no em/en dashes) per
/// project rules.
const PATTERNS = [_]Pattern{
    // --- git, remote-affecting ---
    .{ .needle1 = "git push", .needle2 = "--force", .note = "Note: force-push may overwrite remote history and discard others' commits." },
    .{ .needle1 = "git push", .needle2 = "-f", .note = "Note: force-push may overwrite remote history and discard others' commits." },

    // --- git, local-destructive ---
    .{ .needle1 = "git reset", .needle2 = "--hard", .note = "Note: hard reset discards uncommitted changes in tracked files." },
    .{ .needle1 = "git clean", .needle2 = "-f", .note = "Note: git clean -f permanently deletes untracked files." },
    .{ .needle1 = "git checkout", .needle2 = ".", .note = "Note: checkout . discards uncommitted changes in the working tree." },
    .{ .needle1 = "git restore", .needle2 = ".", .note = "Note: restore . discards uncommitted changes in the working tree." },
    .{ .needle1 = "git stash drop", .note = "Note: dropping a stash permanently removes those stashed changes." },
    .{ .needle1 = "git stash clear", .note = "Note: clearing stashes permanently removes all stashed changes." },
    .{ .needle1 = "git branch", .needle2 = "-D", .note = "Note: branch -D force-deletes a branch even if it is not merged." },
    .{ .needle1 = "git commit", .needle2 = "--amend", .note = "Note: amending rewrites the last commit; avoid amending pushed commits." },
    .{ .needle1 = "--no-verify", .note = "Note: --no-verify skips git hooks (pre-commit / pre-push safety checks)." },

    // --- filesystem ---
    .{ .needle1 = "rm -rf", .note = "Note: recursive force-remove permanently deletes files and directories." },
    .{ .needle1 = "rm -fr", .note = "Note: recursive force-remove permanently deletes files and directories." },
    .{ .needle1 = "rm -f", .note = "Note: force-remove deletes files without prompting." },

    // --- databases (word-bounded SQL keywords) ---
    .{ .needle1 = "drop table", .note = "Note: DROP TABLE permanently destroys a database table and its data.", .word_bounded = true },
    .{ .needle1 = "drop database", .note = "Note: DROP DATABASE permanently destroys an entire database.", .word_bounded = true },
    .{ .needle1 = "truncate table", .note = "Note: TRUNCATE TABLE permanently empties a database table.", .word_bounded = true },
    .{ .needle1 = "delete from", .note = "Note: DELETE FROM removes rows; without a WHERE clause it empties the table.", .word_bounded = true },

    // --- infrastructure ---
    .{ .needle1 = "kubectl delete", .note = "Note: kubectl delete removes Kubernetes resources from the cluster." },
    .{ .needle1 = "terraform destroy", .note = "Note: terraform destroy tears down provisioned infrastructure." },
};

/// Return a rodata advisory string for `command`, or null when no curated
/// destructive pattern matches. The returned slice is static (never owned by
/// the caller); do not free it.
pub fn warning(command: []const u8) ?[]const u8 {
    for (PATTERNS) |p| {
        const first_ok = if (p.word_bounded)
            containsWordBounded(command, p.needle1)
        else
            contains(command, p.needle1);
        if (!first_ok) continue;
        if (p.needle2.len != 0 and !contains(command, p.needle2)) continue;
        return p.note;
    }
    return null;
}

/// Case-insensitive substring match that additionally requires the match to
/// sit on word boundaries on both sides (a non-[A-Za-z0-9_] char, or the
/// string edge). This keeps SQL keyword matches from firing inside larger
/// identifiers (e.g. "deleted" should not match "delete"). Embedded spaces in
/// `needle` are matched literally, which is the intent for "delete from".
fn containsWordBounded(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (!parse_helpers.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) continue;
        const left_ok = (i == 0) or !isWordChar(haystack[i - 1]);
        const right_index = i + needle.len;
        const right_ok = (right_index == haystack.len) or !isWordChar(haystack[right_index]);
        if (left_ok and right_ok) return true;
    }
    return false;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "warning: git force-push" {
    const w = warning("git push --force origin main") orelse return error.TestUnexpectedResult;
    try std.testing.expect(parse_helpers.containsIgnoreCase(w, "remote history"));
    const w2 = warning("git push -f origin main") orelse return error.TestUnexpectedResult;
    try std.testing.expect(parse_helpers.containsIgnoreCase(w2, "remote history"));
}

test "warning: git reset --hard" {
    const w = warning("git reset --hard HEAD~3") orelse return error.TestUnexpectedResult;
    try std.testing.expect(parse_helpers.containsIgnoreCase(w, "uncommitted changes"));
}

test "warning: kubectl delete" {
    const w = warning("kubectl delete pod x") orelse return error.TestUnexpectedResult;
    try std.testing.expect(parse_helpers.containsIgnoreCase(w, "Kubernetes"));
}

test "warning: benign command returns null" {
    try std.testing.expect(warning("ls -la") == null);
    try std.testing.expect(warning("git status") == null);
    try std.testing.expect(warning("echo hello") == null);
}

test "warning: more git patterns" {
    try std.testing.expect(warning("git clean -fd") != null);
    try std.testing.expect(warning("git branch -D feature") != null);
    try std.testing.expect(warning("git commit --amend") != null);
    try std.testing.expect(warning("git stash drop") != null);
    try std.testing.expect(warning("npm test --no-verify") != null);
    // bare `git push` without force should NOT warn.
    try std.testing.expect(warning("git push origin main") == null);
    // bare `git checkout` without `.` should NOT warn here.
    try std.testing.expect(warning("git checkout main") == null);
}

test "warning: filesystem rm" {
    try std.testing.expect(warning("rm -rf build/") != null);
    try std.testing.expect(warning("rm -fr build/") != null);
    try std.testing.expect(warning("rm -f file.txt") != null);
    try std.testing.expect(warning("rm file.txt") == null);
}

test "warning: SQL word-bounded matching" {
    try std.testing.expect(warning("psql -c 'DELETE FROM users'") != null);
    try std.testing.expect(warning("DROP TABLE accounts") != null);
    try std.testing.expect(warning("TRUNCATE TABLE logs") != null);
    try std.testing.expect(warning("DROP DATABASE prod") != null);
    // word-boundary guard: identifiers containing the keyword must not trip.
    try std.testing.expect(warning("ls deleted_from_disk") == null);
    try std.testing.expect(warning("cat droptable_notes.txt") == null);
}

test "warning: infra terraform" {
    try std.testing.expect(warning("terraform destroy -auto-approve") != null);
}
