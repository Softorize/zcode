//! P6 (PRD #534) session markdown export. Renders a conversation history as
//! Markdown for sharing/reading (Claude Code's /export markdown form). zcode
//! already exports JSON; this adds the human-readable form. Pure: turns in,
//! markdown out (caller frees).
//!
//! sessions-05 adds two things on top of the plain role-section render:
//!   - Tool turns carry an internal artifact-wrapper marker
//!     (`tool=<name>\nargs=...\nstate=...\nrisk=...\noutput=...`, written by
//!     `agent_runtime.appendHistoryTurn(.tool, ...)`). When that marker is
//!     present we label the section `### Tool call: <name>` and fence the
//!     body so a tool call/result reads as a distinct, structured block. When
//!     it is absent we fall back to the old `## Tool result` + raw text.
//!   - `defaultFilename` derives a useful export name from the first user
//!     prompt (sanitized slug) or a timestamp, instead of the static
//!     `session-export.md`.

const std = @import("std");
const types = @import("types.zig");
const sb = @import("std_io.zig");

fn heading(role: types.HistoryRole) []const u8 {
    return switch (role) {
        .user => "## User",
        .assistant => "## Assistant",
        .system => "## System",
        .tool => "## Tool result",
    };
}

/// The internal tool-turn artifact-wrapper marker. A `.tool` turn whose
/// content begins with this is a structured tool call/result block emitted by
/// `agent_runtime`; anything else is raw text we fall back on.
const TOOL_MARKER = "tool=";

/// Extract the tool name from a tool-turn body of the form
/// `tool=<name>\nargs=...`. Returns null when the marker is absent so the
/// caller can fall back to the plain `## Tool result` rendering.
fn toolName(content: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, content, TOOL_MARKER)) return null;
    const rest = content[TOOL_MARKER.len..];
    const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    const name = std.mem.trim(u8, rest[0..nl], " \t\r");
    if (name.len == 0) return null;
    return name;
}

/// Render a single tool turn. With the marker present, emit a labeled,
/// fenced section so the call's name/args/state and its output read as a
/// distinct block; without it, fall back to the plain `## Tool result`.
fn writeToolTurn(w: anytype, body: []const u8) !void {
    if (toolName(body)) |name| {
        try w.print("\n### Tool call: {s}\n\n```\n{s}\n```\n", .{ name, body });
    } else {
        try w.print("\n## Tool result\n\n{s}\n", .{body});
    }
}

/// Render `history` to Markdown with a top-level title and a section per turn.
pub fn toMarkdown(allocator: std.mem.Allocator, title: []const u8, history: []const types.HistoryTurn) ![]u8 {
    var builder = sb.StringBuilder.init(allocator);
    defer builder.deinit();
    const w = builder.writer();

    try w.print("# {s}\n", .{title});
    for (history) |t| {
        const body = std.mem.trim(u8, t.content, " \t\r\n");
        if (body.len == 0) continue;
        if (t.role == .tool) {
            try writeToolTurn(w, body);
        } else {
            try w.print("\n{s}\n\n{s}\n", .{ heading(t.role), body });
        }
    }
    return allocator.dupe(u8, builder.items());
}

/// Maximum slug length (characters) for the first-prompt-derived filename,
/// before the `.md` extension. Keeps names short and shell-friendly.
const MAX_SLUG_LEN = 50;

/// Sanitize `first_prompt` into a filename slug: lowercase ASCII, every run
/// of non-`[a-z0-9]` collapsed to a single `-`, leading/trailing `-`
/// trimmed, truncated to `MAX_SLUG_LEN`. Returns an empty slice when nothing
/// usable remains (caller falls back to a timestamp). Caller owns the result.
///
/// This is deliberately strict (no `.`, no `/`, no `..`) so the derived name
/// cannot escape the workspace - the `/export` path-traversal guard still
/// applies on top, but the slug never produces a traversal in the first place.
fn slugify(allocator: std.mem.Allocator, first_prompt: []const u8) ![]u8 {
    var buf = std.Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    var pending_dash = false;
    var emitted: usize = 0;
    for (first_prompt) |c| {
        if (emitted >= MAX_SLUG_LEN) break;
        const lower = std.ascii.toLower(c);
        if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9')) {
            if (pending_dash and emitted > 0) {
                try w.writeByte('-');
                emitted += 1;
                if (emitted >= MAX_SLUG_LEN) break;
            }
            pending_dash = false;
            try w.writeByte(lower);
            emitted += 1;
        } else {
            // Any non-alphanumeric byte becomes a single collapsed dash,
            // deferred so a trailing run does not leave a dangling `-`.
            pending_dash = true;
        }
    }

    var list = buf.toArrayList();
    return list.toOwnedSlice(allocator);
}

/// Derive the default export filename. When the first prompt sanitizes to a
/// non-empty slug, returns `<slug>.md`; otherwise falls back to a
/// timestamp-derived `session-YYYYMMDD-HHMMSS.md` using `ts` (epoch seconds,
/// UTC). `ts` is passed in (not read from the clock) so callers stay testable;
/// production callers pass `clock.nowSeconds()`. Caller owns the result.
pub fn defaultFilename(allocator: std.mem.Allocator, first_prompt: []const u8, ts: i64) ![]u8 {
    const slug = try slugify(allocator, first_prompt);
    defer allocator.free(slug);
    if (slug.len > 0) {
        return std.fmt.allocPrint(allocator, "{s}.md", .{slug});
    }

    const secs_u64: u64 = @intCast(@max(ts, 0));
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = secs_u64 };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();
    const hour = day_secs.getHoursIntoDay();
    const minute = day_secs.getMinutesIntoHour();
    const second = day_secs.getSecondsIntoMinute();
    return std.fmt.allocPrint(
        allocator,
        "session-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}.md",
        .{
            @as(u32, @intCast(year_day.year)),
            @as(u32, month_day.month.numeric()),
            @as(u32, month_day.day_index + 1),
            @as(u32, hour),
            @as(u32, minute),
            @as(u32, second),
        },
    );
}

const testing = std.testing;

fn turn(role: types.HistoryRole, content: []const u8) types.HistoryTurn {
    return .{ .role = role, .content = content, .timestamp = 0 };
}

test "renders title and role sections" {
    const history = [_]types.HistoryTurn{
        turn(.user, "hello"),
        turn(.assistant, "hi there"),
    };
    const md = try toMarkdown(testing.allocator, "My Session", &history);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.startsWith(u8, md, "# My Session\n"));
    try testing.expect(std.mem.indexOf(u8, md, "## User\n\nhello") != null);
    try testing.expect(std.mem.indexOf(u8, md, "## Assistant\n\nhi there") != null);
}

test "skips empty turns" {
    const history = [_]types.HistoryTurn{
        turn(.user, "   "),
        turn(.assistant, "answer"),
    };
    const md = try toMarkdown(testing.allocator, "T", &history);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "## User") == null);
    try testing.expect(std.mem.indexOf(u8, md, "## Assistant\n\nanswer") != null);
}

test "tool turn with marker renders a fenced Tool call section" {
    const tool_body =
        "tool=Bash\nargs={\"command\":\"ls\"}\nstate=approved\nrisk=low\noutput=file.txt";
    const history = [_]types.HistoryTurn{
        turn(.user, "list files"),
        turn(.tool, tool_body),
    };
    const md = try toMarkdown(testing.allocator, "T", &history);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "### Tool call: Bash") != null);
    // The body is fenced.
    try testing.expect(std.mem.indexOf(u8, md, "```\ntool=Bash") != null);
    // It must NOT use the plain fallback heading.
    try testing.expect(std.mem.indexOf(u8, md, "## Tool result") == null);
}

test "tool turn without marker falls back to plain Tool result" {
    const history = [_]types.HistoryTurn{
        turn(.tool, "exit 0"),
    };
    const md = try toMarkdown(testing.allocator, "T", &history);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "## Tool result\n\nexit 0") != null);
    try testing.expect(std.mem.indexOf(u8, md, "### Tool call") == null);
}

test "defaultFilename slugs the first prompt" {
    const name = try defaultFilename(testing.allocator, "Fix the login button!", 0);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("fix-the-login-button.md", name);
}

test "defaultFilename collapses runs and trims edges" {
    const name = try defaultFilename(testing.allocator, "  Hello,   WORLD -- foo!!  ", 0);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("hello-world-foo.md", name);
}

test "defaultFilename never produces path traversal" {
    const name = try defaultFilename(testing.allocator, "../../etc/passwd", 0);
    defer testing.allocator.free(name);
    try testing.expect(std.mem.indexOf(u8, name, "..") == null);
    try testing.expect(std.mem.indexOf(u8, name, "/") == null);
    try testing.expectEqualStrings("etc-passwd.md", name);
}

test "defaultFilename falls back to timestamp when prompt is empty" {
    const name = try defaultFilename(testing.allocator, "   !!!   ", 0);
    defer testing.allocator.free(name);
    // 1970-01-01 00:00:00 UTC.
    try testing.expectEqualStrings("session-19700101-000000.md", name);
    try testing.expect(std.mem.startsWith(u8, name, "session-"));
    try testing.expect(std.mem.endsWith(u8, name, ".md"));
}

test "defaultFilename truncates long slugs" {
    const long = "a" ** 200;
    const name = try defaultFilename(testing.allocator, long, 0);
    defer testing.allocator.free(name);
    // MAX_SLUG_LEN slug chars + ".md".
    try testing.expectEqual(@as(usize, MAX_SLUG_LEN + 3), name.len);
    try testing.expect(std.mem.endsWith(u8, name, ".md"));
}
