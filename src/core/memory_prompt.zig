//! Memory taxonomy + save-instruction prompt block (memory-02).
//!
//! Ports the reference's `buildMemoryLines` / taxonomy text into Zig so the
//! main agent self-manages its persistent file-based memory. The text teaches
//! the closed four-type taxonomy (`user`, `feedback`, `project`, `reference`),
//! when/how to save, what NOT to save, the two-step `MEMORY.md` save protocol,
//! and a grep-based "Searching past context" section.
//!
//! Reference:
//!   - claude-code-main/src/memdir/memdir.ts:199-266 (`buildMemoryLines`)
//!   - claude-code-main/src/memdir/memdir.ts:375-407 (`buildSearchingPastContextSection`)
//!   - claude-code-main/src/memdir/memoryTypes.ts:113-271 (the section constants)
//!
//! DIVERGENCE FROM zcode's memory.zig categories. zcode's `memory.zig`
//! recognizes two extra categories the reference lacks -- `rule` / `always`
//! -- which drive the `# ABSOLUTE RULES` always-include render. Those stay as a
//! zcode-only extension in memory.zig. This taxonomy *prompt* intentionally
//! teaches ONLY the four reference types so the model writes parity-shaped
//! files (frontmatter `type:` is one of the four). Do not add `rule`/`always`
//! to the taxonomy text here.
//!
//! NO-LONG-DASH NOTE. The reference text is full of em dashes (U+2014), en
//! dashes (U+2013), and right-arrows (U+2192). Per the project's hard no-long-
//! dash rule every one of those is rewritten to a plain hyphen (or the text is
//! reworded) in the ported constants below. A unit test asserts the output
//! contains no em/en-dash byte sequence.

const std = @import("std");
const std_io = @import("std_io.zig");

// ---------------------------------------------------------------------------
// Entrypoint constants (shared with Task 3 / dream.zig).
// ---------------------------------------------------------------------------

pub const ENTRYPOINT_NAME = "MEMORY.md";
pub const MAX_ENTRYPOINT_LINES = 200;
pub const MAX_ENTRYPOINT_BYTES = 25_000;

// ---------------------------------------------------------------------------
// MEMORY.md index truncation (memory-04 + memory-11).
// Ported from memdir.ts:57-103 (`truncateEntrypointContent`). The index is
// always loaded into the system prompt, so it is capped on BOTH a line limit
// (200) and a byte limit (25000). Line-truncation happens first (a natural
// boundary), then byte-truncation cuts at the last newline before the cap so
// no line is severed mid-content. A warning naming exactly which cap fired is
// appended. The byte check uses the ORIGINAL trimmed byte count (not the post-
// line-truncation size) so long-line indexes -- the failure mode the byte cap
// targets -- still trigger the byte warning.
//
// NO-LONG-DASH NOTE. The reference's bytes-only reason text uses an em dash
// (" — index entries are too long"); it is rewritten to a plain hyphen here.
// ---------------------------------------------------------------------------

pub const Truncation = struct {
    /// The (possibly truncated) content, with the warning appended when a cap
    /// fired. Caller owns this slice.
    content: []u8,
    /// Line count of the original trimmed input (split on '\n', JS-`split`
    /// semantics: N newlines -> N+1 segments for a non-empty string).
    line_count: usize,
    /// Byte count of the original trimmed input.
    byte_count: usize,
    was_line_truncated: bool,
    was_byte_truncated: bool,
};

/// Format a byte size the way the reference's `formatFileSize` does
/// (utils/format.ts:9): "<n> bytes" below 1KB, "<x.y>KB"/"<x.y>MB"/"<x.y>GB"
/// above, trimming a trailing ".0". Caller owns the returned slice.
fn formatFileSize(allocator: std.mem.Allocator, size_in_bytes: usize) ![]u8 {
    const bytes_f: f64 = @floatFromInt(size_in_bytes);
    const kb = bytes_f / 1024.0;
    if (kb < 1.0) {
        return std.fmt.allocPrint(allocator, "{d} bytes", .{size_in_bytes});
    }
    if (kb < 1024.0) {
        return formatOneDecimal(allocator, kb, "KB");
    }
    const mb = kb / 1024.0;
    if (mb < 1024.0) {
        return formatOneDecimal(allocator, mb, "MB");
    }
    const gb = mb / 1024.0;
    return formatOneDecimal(allocator, gb, "GB");
}

/// Print `value` to one decimal place, drop a trailing ".0", then append the
/// unit suffix. Mirrors the reference `toFixed(1).replace(/\.0$/, '')` shape.
fn formatOneDecimal(allocator: std.mem.Allocator, value: f64, unit: []const u8) ![]u8 {
    var buf: [64]u8 = undefined;
    const one_dp = try std.fmt.bufPrint(&buf, "{d:.1}", .{value});
    const trimmed = if (std.mem.endsWith(u8, one_dp, ".0"))
        one_dp[0 .. one_dp.len - 2]
    else
        one_dp;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed, unit });
}

/// Count lines the way JS `string.split('\n').length` does: a non-empty string
/// with K newlines yields K+1 segments; the empty string yields 1.
fn countLines(s: []const u8) usize {
    var count: usize = 1;
    for (s) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

/// Slice off everything after the first `max_lines` lines (the first
/// `max_lines - 1` newlines plus the run of text up to the next newline).
/// Returns a sub-slice of `s` (no allocation). When `s` has at most
/// `max_lines` lines, returns `s` unchanged.
fn takeFirstLines(s: []const u8, max_lines: usize) []const u8 {
    if (max_lines == 0) return s[0..0];
    var seen: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\n') {
            seen += 1;
            if (seen == max_lines) return s[0..i];
        }
    }
    return s;
}

/// Truncate `MEMORY.md` content to the line AND byte caps, appending a warning
/// naming which cap fired. See the module-level note above for the algorithm.
/// `raw` is the on-disk content (caller does not need to pre-trim).
/// Caller owns `Truncation.content`.
pub fn truncateEntrypoint(allocator: std.mem.Allocator, raw: []const u8) !Truncation {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const line_count = countLines(trimmed);
    const byte_count = trimmed.len;

    const was_line_truncated = line_count > MAX_ENTRYPOINT_LINES;
    // Check the ORIGINAL byte count: long lines are the failure mode the byte
    // cap targets, so the post-line-truncation size would understate it.
    const was_byte_truncated = byte_count > MAX_ENTRYPOINT_BYTES;

    if (!was_line_truncated and !was_byte_truncated) {
        return .{
            .content = try allocator.dupe(u8, trimmed),
            .line_count = line_count,
            .byte_count = byte_count,
            .was_line_truncated = false,
            .was_byte_truncated = false,
        };
    }

    // Line-truncate first (natural boundary), then byte-truncate at the last
    // newline at or before the cap so we never cut mid-line.
    var truncated: []const u8 = if (was_line_truncated)
        takeFirstLines(trimmed, MAX_ENTRYPOINT_LINES)
    else
        trimmed;

    if (truncated.len > MAX_ENTRYPOINT_BYTES) {
        // lastIndexOf('\n', MAX_ENTRYPOINT_BYTES): the last newline at or before
        // the cap index. Search within the [0, cap] prefix.
        const search_end = @min(truncated.len, MAX_ENTRYPOINT_BYTES + 1);
        const cut_at: ?usize = std.mem.lastIndexOfScalar(u8, truncated[0..search_end], '\n');
        if (cut_at) |idx| {
            // idx > 0 in practice; fall back to the hard cap if the only
            // newline is at byte 0 (degenerate leading-newline input).
            truncated = truncated[0..(if (idx > 0) idx else MAX_ENTRYPOINT_BYTES)];
        } else {
            truncated = truncated[0..MAX_ENTRYPOINT_BYTES];
        }
    }

    // Build the cap-naming reason.
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().writeAll(truncated);
    try out.writer().writeAll("\n\n> WARNING: " ++ ENTRYPOINT_NAME ++ " is ");

    if (was_byte_truncated and !was_line_truncated) {
        const bc = try formatFileSize(allocator, byte_count);
        defer allocator.free(bc);
        const lim = try formatFileSize(allocator, MAX_ENTRYPOINT_BYTES);
        defer allocator.free(lim);
        try out.writer().print("{s} (limit: {s}) - index entries are too long", .{ bc, lim });
    } else if (was_line_truncated and !was_byte_truncated) {
        try out.writer().print("{d} lines (limit: {d})", .{ line_count, MAX_ENTRYPOINT_LINES });
    } else {
        const bc = try formatFileSize(allocator, byte_count);
        defer allocator.free(bc);
        try out.writer().print("{d} lines and {s}", .{ line_count, bc });
    }

    try out.writer().writeAll(". Only part of it was loaded. Keep index entries to one line under ~200 chars; move detail into topic files.");

    return .{
        .content = try out.toOwnedSlice(),
        .line_count = line_count,
        .byte_count = byte_count,
        .was_line_truncated = was_line_truncated,
        .was_byte_truncated = was_byte_truncated,
    };
}

const DIR_EXISTS_GUIDANCE =
    "This directory already exists - write to it directly with the Write tool (do not run mkdir or check for its existence).";

// ---------------------------------------------------------------------------
// `## Types of memory` (INDIVIDUAL-only variant, no <scope> tags).
// Ported from memoryTypes.ts:113-178 (TYPES_SECTION_INDIVIDUAL).
// All em/en dashes and arrows rewritten to plain hyphens.
// ---------------------------------------------------------------------------

// Exposed pub so the turn-end extraction agent (core/extract_memories.zig)
// can reuse the exact same taxonomy text the system prompt teaches, keeping
// the main-agent write path and the forked extraction write path in sync.
pub const TYPES_SECTION_INDIVIDUAL =
    \\## Types of memory
    \\
    \\There are several discrete types of memory that you can store in your memory system:
    \\
    \\<types>
    \\<type>
    \\    <name>user</name>
    \\    <description>Contain information about the user's role, goals, responsibilities, and knowledge. Great user memories help you tailor your future behavior to the user's preferences and perspective. Your goal in reading and writing these memories is to build up an understanding of who the user is and how you can be most helpful to them specifically. For example, you should collaborate with a senior software engineer differently than a student who is coding for the very first time. Keep in mind, that the aim here is to be helpful to the user. Avoid writing memories about the user that could be viewed as a negative judgement or that are not relevant to the work you're trying to accomplish together.</description>
    \\    <when_to_save>When you learn any details about the user's role, preferences, responsibilities, or knowledge</when_to_save>
    \\    <how_to_use>When your work should be informed by the user's profile or perspective. For example, if the user is asking you to explain a part of the code, you should answer that question in a way that is tailored to the specific details that they will find most valuable or that helps them build their mental model in relation to domain knowledge they already have.</how_to_use>
    \\    <examples>
    \\    user: I'm a data scientist investigating what logging we have in place
    \\    assistant: [saves user memory: user is a data scientist, currently focused on observability/logging]
    \\
    \\    user: I've been writing Go for ten years but this is my first time touching the React side of this repo
    \\    assistant: [saves user memory: deep Go expertise, new to React and this project's frontend - frame frontend explanations in terms of backend analogues]
    \\    </examples>
    \\</type>
    \\<type>
    \\    <name>feedback</name>
    \\    <description>Guidance the user has given you about how to approach work - both what to avoid and what to keep doing. These are a very important type of memory to read and write as they allow you to remain coherent and responsive to the way you should approach work in the project. Record from failure AND success: if you only save corrections, you will avoid past mistakes but drift away from approaches the user has already validated, and may grow overly cautious.</description>
    \\    <when_to_save>Any time the user corrects your approach ("no not that", "don't", "stop doing X") OR confirms a non-obvious approach worked ("yes exactly", "perfect, keep doing that", accepting an unusual choice without pushback). Corrections are easy to notice; confirmations are quieter - watch for them. In both cases, save what is applicable to future conversations, especially if surprising or not obvious from the code. Include *why* so you can judge edge cases later.</when_to_save>
    \\    <how_to_use>Let these memories guide your behavior so that the user does not need to offer the same guidance twice.</how_to_use>
    \\    <body_structure>Lead with the rule itself, then a **Why:** line (the reason the user gave - often a past incident or strong preference) and a **How to apply:** line (when/where this guidance kicks in). Knowing *why* lets you judge edge cases instead of blindly following the rule.</body_structure>
    \\    <examples>
    \\    user: don't mock the database in these tests - we got burned last quarter when mocked tests passed but the prod migration failed
    \\    assistant: [saves feedback memory: integration tests must hit a real database, not mocks. Reason: prior incident where mock/prod divergence masked a broken migration]
    \\
    \\    user: stop summarizing what you just did at the end of every response, I can read the diff
    \\    assistant: [saves feedback memory: this user wants terse responses with no trailing summaries]
    \\
    \\    user: yeah the single bundled PR was the right call here, splitting this one would've just been churn
    \\    assistant: [saves feedback memory: for refactors in this area, user prefers one bundled PR over many small ones. Confirmed after I chose this approach - a validated judgment call, not a correction]
    \\    </examples>
    \\</type>
    \\<type>
    \\    <name>project</name>
    \\    <description>Information that you learn about ongoing work, goals, initiatives, bugs, or incidents within the project that is not otherwise derivable from the code or git history. Project memories help you understand the broader context and motivation behind the work the user is doing within this working directory.</description>
    \\    <when_to_save>When you learn who is doing what, why, or by when. These states change relatively quickly so try to keep your understanding of this up to date. Always convert relative dates in user messages to absolute dates when saving (e.g., "Thursday" to "2026-03-05"), so the memory remains interpretable after time passes.</when_to_save>
    \\    <how_to_use>Use these memories to more fully understand the details and nuance behind the user's request and make better informed suggestions.</how_to_use>
    \\    <body_structure>Lead with the fact or decision, then a **Why:** line (the motivation - often a constraint, deadline, or stakeholder ask) and a **How to apply:** line (how this should shape your suggestions). Project memories decay fast, so the why helps future-you judge whether the memory is still load-bearing.</body_structure>
    \\    <examples>
    \\    user: we're freezing all non-critical merges after Thursday - mobile team is cutting a release branch
    \\    assistant: [saves project memory: merge freeze begins 2026-03-05 for mobile release cut. Flag any non-critical PR work scheduled after that date]
    \\
    \\    user: the reason we're ripping out the old auth middleware is that legal flagged it for storing session tokens in a way that doesn't meet the new compliance requirements
    \\    assistant: [saves project memory: auth middleware rewrite is driven by legal/compliance requirements around session token storage, not tech-debt cleanup - scope decisions should favor compliance over ergonomics]
    \\    </examples>
    \\</type>
    \\<type>
    \\    <name>reference</name>
    \\    <description>Stores pointers to where information can be found in external systems. These memories allow you to remember where to look to find up-to-date information outside of the project directory.</description>
    \\    <when_to_save>When you learn about resources in external systems and their purpose. For example, that bugs are tracked in a specific project in Linear or that feedback can be found in a specific Slack channel.</when_to_save>
    \\    <how_to_use>When the user references an external system or information that may be in an external system.</how_to_use>
    \\    <examples>
    \\    user: check the Linear project "INGEST" if you want context on these tickets, that's where we track all pipeline bugs
    \\    assistant: [saves reference memory: pipeline bugs are tracked in Linear project "INGEST"]
    \\
    \\    user: the Grafana board at grafana.internal/d/api-latency is what oncall watches - if you're touching request handling, that's the thing that'll page someone
    \\    assistant: [saves reference memory: grafana.internal/d/api-latency is the oncall latency dashboard - check it when editing request-path code]
    \\    </examples>
    \\</type>
    \\</types>
    \\
;

// ---------------------------------------------------------------------------
// `## What NOT to save in memory`. Ported from memoryTypes.ts:183-195.
// ---------------------------------------------------------------------------

pub const WHAT_NOT_TO_SAVE_SECTION =
    \\## What NOT to save in memory
    \\
    \\- Code patterns, conventions, architecture, file paths, or project structure - these can be derived by reading the current project state.
    \\- Git history, recent changes, or who-changed-what - `git log` / `git blame` are authoritative.
    \\- Debugging solutions or fix recipes - the fix is in the code; the commit message has the context.
    \\- Anything already documented in CLAUDE.md files.
    \\- Ephemeral task details: in-progress work, temporary state, current conversation context.
    \\
    \\These exclusions apply even when the user explicitly asks you to save. If they ask you to save a PR list or activity summary, ask what was *surprising* or *non-obvious* about it - that is the part worth keeping.
    \\
;

// ---------------------------------------------------------------------------
// `## When to access memories` (includes the ignore-bullet + drift caveat).
// Ported from memoryTypes.ts:216-222 (WHEN_TO_ACCESS_SECTION + drift caveat).
// ---------------------------------------------------------------------------

const WHEN_TO_ACCESS_SECTION =
    \\## When to access memories
    \\- When memories seem relevant, or the user references prior-conversation work.
    \\- You MUST access memory when the user explicitly asks you to check, recall, or remember.
    \\- If the user says to *ignore* or *not use* memory: proceed as if MEMORY.md were empty. Do not apply remembered facts, cite, compare against, or mention memory content.
    \\- Memory records can become stale over time. Use memory as context for what was true at a given point in time. Before answering the user or building assumptions based solely on information in memory records, verify that the memory is still correct and up-to-date by reading the current state of the files or resources. If a recalled memory conflicts with current information, trust what you observe now - and update or remove the stale memory rather than acting on it.
    \\
;

// ---------------------------------------------------------------------------
// `## Before recommending from memory`. Ported from memoryTypes.ts:240-256.
// ---------------------------------------------------------------------------

const TRUSTING_RECALL_SECTION =
    \\## Before recommending from memory
    \\
    \\A memory that names a specific function, file, or flag is a claim that it existed *when the memory was written*. It may have been renamed, removed, or never merged. Before recommending it:
    \\
    \\- If the memory names a file path: check the file exists.
    \\- If the memory names a function or flag: grep for it.
    \\- If the user is about to act on your recommendation (not just asking about history), verify first.
    \\
    \\"The memory says X exists" is not the same as "X exists now."
    \\
    \\A memory that summarizes repo state (activity logs, architecture snapshots) is frozen in time. If the user asks about *recent* or *current* state, prefer `git log` or reading the code over recalling the snapshot.
    \\
;

// ---------------------------------------------------------------------------
// `## Memory and other forms of persistence`. Ported from memdir.ts:254-257.
// ---------------------------------------------------------------------------

const PERSISTENCE_SECTION =
    \\## Memory and other forms of persistence
    \\Memory is one of several persistence mechanisms available to you as you assist the user in a given conversation. The distinction is often that memory can be recalled in future conversations and should not be used for persisting information that is only useful within the scope of the current conversation.
    \\- When to use or update a plan instead of memory: If you are about to start a non-trivial implementation task and would like to reach alignment with the user on your approach you should use a Plan rather than saving this information to memory. Similarly, if you already have a plan within the conversation and you have changed your approach persist that change by updating the plan rather than saving a memory.
    \\- When to use or update tasks instead of memory: When you need to break your work in current conversation into discrete steps or keep track of your progress use tasks instead of saving to memory. Tasks are great for persisting information about the work that needs to be done in the current conversation, but memory should be reserved for information that will be useful in future conversations.
    \\
;

// MEMORY_FRONTMATTER_EXAMPLE. Ported from memoryTypes.ts:261-271. The
// `{{...}}` placeholders are kept verbatim (the reference shows them to the
// model as a fill-in template).
pub const MEMORY_FRONTMATTER_EXAMPLE =
    \\```markdown
    \\---
    \\name: {{memory name}}
    \\description: {{one-line description - used to decide relevance in future conversations, so be specific}}
    \\type: {{user, feedback, project, reference}}
    \\---
    \\
    \\{{memory content - for feedback/project types, structure as: rule/fact, then **Why:** and **How to apply:** lines}}
    \\```
;

// ---------------------------------------------------------------------------
// Public builders
// ---------------------------------------------------------------------------

/// Build the full memory taxonomy + save-instruction section. `memory_dir` is
/// the resolved auto-memory directory (from memory_gate.getAutoMemPath); it is
/// substituted into the "system at <dir>" line and the search section so the
/// path is never hardcoded to `~/.claude`.
///
/// Caller owns the returned slice.
pub fn buildMemoryLines(allocator: std.mem.Allocator, memory_dir: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    const w = out.writer();

    // Header + intro. Ported from memdir.ts:236-243.
    try w.print(
        "# auto memory\n" ++
            "\n" ++
            "You have a persistent, file-based memory system at `{s}`. " ++ DIR_EXISTS_GUIDANCE ++ "\n" ++
            "\n" ++
            "You should build up this memory system over time so that future conversations can have a complete picture of who the user is, how they'd like to collaborate with you, what behaviors to avoid or repeat, and the context behind the work the user gives you.\n" ++
            "\n" ++
            "If the user explicitly asks you to remember something, save it immediately as whichever type fits best. If they ask you to forget something, find and remove the relevant entry.\n" ++
            "\n",
        .{memory_dir},
    );

    try w.writeAll(TYPES_SECTION_INDIVIDUAL);
    try w.writeAll(WHAT_NOT_TO_SAVE_SECTION);
    try w.writeAll("\n");

    // `## How to save memories` (two-step variant). Ported from
    // memdir.ts:218-234 -- references MEMORY.md as the index.
    try w.print(
        "## How to save memories\n" ++
            "\n" ++
            "Saving a memory is a two-step process:\n" ++
            "\n" ++
            "**Step 1** - write the memory to its own file (e.g., `user_role.md`, `feedback_testing.md`) using this frontmatter format:\n" ++
            "\n" ++
            MEMORY_FRONTMATTER_EXAMPLE ++ "\n" ++
            "\n" ++
            "**Step 2** - add a pointer to that file in `" ++ ENTRYPOINT_NAME ++ "`. `" ++ ENTRYPOINT_NAME ++ "` is an index, not a memory - each entry should be one line, under ~150 characters: `- [Title](file.md) - one-line hook`. It has no frontmatter. Never write memory content directly into `" ++ ENTRYPOINT_NAME ++ "`.\n" ++
            "\n" ++
            "- `" ++ ENTRYPOINT_NAME ++ "` is always loaded into your conversation context - lines after {d} will be truncated, so keep the index concise\n" ++
            "- Keep the name, description, and type fields in memory files up-to-date with the content\n" ++
            "- Organize memory semantically by topic, not chronologically\n" ++
            "- Update or remove memories that turn out to be wrong or outdated\n" ++
            "- Do not write duplicate memories. First check if there is an existing memory you can update before writing a new one.\n" ++
            "\n",
        .{MAX_ENTRYPOINT_LINES},
    );

    try w.writeAll(WHEN_TO_ACCESS_SECTION);
    try w.writeAll("\n");
    try w.writeAll(TRUSTING_RECALL_SECTION);
    try w.writeAll("\n");
    try w.writeAll(PERSISTENCE_SECTION);
    try w.writeAll("\n");

    const search = try buildSearchingPastContextSection(allocator, memory_dir);
    defer allocator.free(search);
    try w.writeAll(search);

    return out.toOwnedSlice();
}

/// Build the `## Searching past context` section. zcode's search tool is
/// `Grep`; emit the `Grep with pattern=... path=<dir> glob="*.md"` form.
///
/// The reference gates this on the `tengu_coral_fern` GrowthBook flag; zcode
/// has no GrowthBook, so it is always included (the flag becomes always-on, per
/// the phase's out-of-scope notes).
///
/// Caller owns the returned slice.
pub fn buildSearchingPastContextSection(allocator: std.mem.Allocator, memory_dir: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    try out.writer().print(
        "## Searching past context\n" ++
            "\n" ++
            "When looking for past context:\n" ++
            "1. Search topic files in your memory directory:\n" ++
            "```\n" ++
            "Grep with pattern=\"<search term>\" path=\"{s}\" glob=\"*.md\"\n" ++
            "```\n" ++
            "Use narrow search terms (error messages, file paths, function names) rather than broad keywords.\n",
        .{memory_dir},
    );

    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "buildMemoryLines contains the four type names and key section markers" {
    const a = testing.allocator;
    const out = try buildMemoryLines(a, "/tmp/zcode-test/memory");
    defer a.free(out);

    // Four reference type names.
    try testing.expect(std.mem.indexOf(u8, out, "<name>user</name>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<name>feedback</name>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<name>project</name>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<name>reference</name>") != null);

    // The literal taxonomy tag.
    try testing.expect(std.mem.indexOf(u8, out, "<when_to_save>") != null);

    // Section headers / protocol strings.
    try testing.expect(std.mem.indexOf(u8, out, "## Types of memory") != null);
    try testing.expect(std.mem.indexOf(u8, out, "## What NOT to save in memory") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Saving a memory is a two-step process") != null);
    try testing.expect(std.mem.indexOf(u8, out, "MEMORY.md") != null);
    try testing.expect(std.mem.indexOf(u8, out, "## Searching past context") != null);

    // The zcode-only `rule`/`always` categories must NOT leak into the
    // taxonomy text (parity-shaped four-type teaching only).
    try testing.expect(std.mem.indexOf(u8, out, "<name>rule</name>") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<name>always</name>") == null);
}

test "buildMemoryLines output contains no em dash or en dash bytes" {
    const a = testing.allocator;
    const out = try buildMemoryLines(a, "/tmp/zcode-test/memory");
    defer a.free(out);

    // U+2014 EM DASH  -> UTF-8 0xE2 0x80 0x94
    // U+2013 EN DASH  -> UTF-8 0xE2 0x80 0x93
    // U+2192 RIGHTWARDS ARROW -> UTF-8 0xE2 0x86 0x92 (reference uses these too)
    const em_dash = "\xE2\x80\x94";
    const en_dash = "\xE2\x80\x93";
    const right_arrow = "\xE2\x86\x92";
    try testing.expect(std.mem.indexOf(u8, out, em_dash) == null);
    try testing.expect(std.mem.indexOf(u8, out, en_dash) == null);
    try testing.expect(std.mem.indexOf(u8, out, right_arrow) == null);
}

test "buildMemoryLines substitutes the resolved memory dir (not ~/.claude)" {
    const a = testing.allocator;
    const dir = "/Users/x/.zcode/memory";
    const out = try buildMemoryLines(a, dir);
    defer a.free(out);

    // The supplied dir appears in both the header line and the search section.
    try testing.expect(std.mem.indexOf(u8, out, dir) != null);
    // It must not hardcode the reference default.
    try testing.expect(std.mem.indexOf(u8, out, "~/.claude") == null);
    // And the search section must reference it as the Grep path.
    const needle = "path=\"" ++ dir ++ "\" glob=\"*.md\"";
    try testing.expect(std.mem.indexOf(u8, out, needle) != null);
}

test "buildSearchingPastContextSection emits the Grep form with the dir" {
    const a = testing.allocator;
    const out = try buildSearchingPastContextSection(a, "/m/dir");
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "## Searching past context") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Grep with pattern=\"<search term>\" path=\"/m/dir\" glob=\"*.md\"") != null);
}

// ---------------------------------------------------------------------------
// truncateEntrypoint tests (memory-04 + memory-11).
// ---------------------------------------------------------------------------

test "truncateEntrypoint line-truncates a 201-line input and names the line cap" {
    const a = testing.allocator;
    // 201 short lines -> over the 200-line cap, under the byte cap.
    var sb = std_io.StringBuilder.init(a);
    defer sb.deinit();
    var i: usize = 0;
    while (i < 201) : (i += 1) {
        try sb.writer().print("line{d}\n", .{i});
    }
    const input = sb.items();

    const t = try truncateEntrypoint(a, input);
    defer a.free(t.content);

    try testing.expect(t.was_line_truncated);
    try testing.expect(!t.was_byte_truncated);
    // The trimmed input has 201 lines (trailing newline is trimmed away, so the
    // final segment is "line200" -> 201 segments).
    try testing.expectEqual(@as(usize, 201), t.line_count);
    // Warning names the line cap.
    try testing.expect(std.mem.indexOf(u8, t.content, "lines (limit: 200)") != null);
    // The kept body holds line0 but not line200 (line-truncated to 200).
    try testing.expect(std.mem.indexOf(u8, t.content, "line0\n") != null);
    try testing.expect(std.mem.indexOf(u8, t.content, "line200") == null);
}

test "truncateEntrypoint byte-truncates a single 30000-byte line and names the byte cap" {
    const a = testing.allocator;
    const line = try a.alloc(u8, 30_000);
    defer a.free(line);
    @memset(line, 'x');

    const t = try truncateEntrypoint(a, line);
    defer a.free(t.content);

    try testing.expect(t.was_byte_truncated);
    try testing.expect(!t.was_line_truncated);
    try testing.expectEqual(@as(usize, 1), t.line_count);
    try testing.expectEqual(@as(usize, 30_000), t.byte_count);
    // Byte-only warning names the byte cap and the "too long" phrasing.
    try testing.expect(std.mem.indexOf(u8, t.content, "index entries are too long") != null);
    try testing.expect(std.mem.indexOf(u8, t.content, "(limit: ") != null);
    // No em dash in the warning (plain hyphen only).
    try testing.expect(std.mem.indexOf(u8, t.content, "\xE2\x80\x94") == null);
}

test "truncateEntrypoint over both caps gets the combined warning" {
    const a = testing.allocator;
    // 300 lines, each 200 bytes -> over 200 lines AND over 25000 bytes.
    var sb = std_io.StringBuilder.init(a);
    defer sb.deinit();
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        var pad: [199]u8 = undefined;
        @memset(&pad, 'a');
        try sb.writer().print("{s}\n", .{pad});
    }
    const input = sb.items();

    const t = try truncateEntrypoint(a, input);
    defer a.free(t.content);

    try testing.expect(t.was_line_truncated);
    try testing.expect(t.was_byte_truncated);
    // Combined reason: "<n> lines and <size>".
    try testing.expect(std.mem.indexOf(u8, t.content, "lines and ") != null);
    // Combined form must NOT use either single-cap phrasing.
    try testing.expect(std.mem.indexOf(u8, t.content, "lines (limit: 200)") == null);
    try testing.expect(std.mem.indexOf(u8, t.content, "index entries are too long") == null);
}

test "truncateEntrypoint under both caps returns trimmed content with no warning" {
    const a = testing.allocator;
    const input = "  \n# Index\n- [foo](foo.md) - a hook\n- [bar](bar.md) - another\n\n  ";

    const t = try truncateEntrypoint(a, input);
    defer a.free(t.content);

    try testing.expect(!t.was_line_truncated);
    try testing.expect(!t.was_byte_truncated);
    // Trimmed: leading/trailing whitespace gone.
    try testing.expectEqualStrings("# Index\n- [foo](foo.md) - a hook\n- [bar](bar.md) - another", t.content);
    // No warning marker.
    try testing.expect(std.mem.indexOf(u8, t.content, "> WARNING:") == null);
}

test "truncateEntrypoint byte truncation cuts at a newline boundary" {
    const a = testing.allocator;
    // Build content over 25000 bytes made of fixed 100-byte lines so a newline
    // exists before the cap. After the cut, the content must end at a newline
    // boundary (no severed line).
    var sb = std_io.StringBuilder.init(a);
    defer sb.deinit();
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        var pad: [99]u8 = undefined;
        @memset(&pad, 'z');
        try sb.writer().print("{s}\n", .{pad});
    }
    const input = sb.items();

    const t = try truncateEntrypoint(a, input);
    defer a.free(t.content);

    try testing.expect(t.was_byte_truncated);
    // The body is everything before the appended "\n\n> WARNING:" marker.
    const warn_idx = std.mem.indexOf(u8, t.content, "\n\n> WARNING:").?;
    const body = t.content[0..warn_idx];
    // The cut happened at a '\n' boundary, so the last kept byte is part of a
    // complete 99-'z' line: the byte just before the cut index was '\n', i.e.
    // the body ends with a full "zzz...z" run, not a partial then no newline.
    // Concretely: body length is a multiple of 100 minus the trailing newline
    // that lastIndexOf landed on, so the final char is 'z'.
    try testing.expect(body.len > 0);
    try testing.expectEqual(@as(u8, 'z'), body[body.len - 1]);
    // And the cut index in the original sits on a newline: body's length should
    // mark a position where input had '\n'.
    try testing.expectEqual(@as(u8, '\n'), input[body.len]);
}
