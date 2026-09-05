//! commands-38: the ONE fully-extractable command-listing algorithm found in
//! the 2.1.261 bundle -- the system prompt's "Available commands (N in this
//! build)" section generator, verified verbatim in cc_strings.txt:
//!
//!   o = ions.commands.filter(e => !e.isHidden)
//!   r = e => e.type !== "prompt" || e.source === "builtin" || e.source === "bundled"
//!   u = o.filter(r)
//!   u.map(t => {
//!     let d = t.aliases?.length ? ` (aliases: ${t.aliases.map(m => `/${m}`).join(", ")})` : ""
//!     return `- /${t.name}${d}: ${t.description}`
//!   }).sort()
//!
//! rendered under a `**Available commands (N in this build):**` header.
//!
//! This is deliberately NOT wired into `cli/repl_help.zig`'s interactive
//! `/help` screen -- per the gap's own finding, no category-header strings
//! for that screen exist anywhere in the reference bundle (it renders a live
//! Ink component with computed-not-hardcoded structure), so zcode's existing
//! sectioned `/help` layout is left as-is. This module is the reusable
//! building block for whichever surface renders the model-facing "commands
//! available in this build" system-prompt section -- ownership of THAT
//! integration point (src/core/system_prompt.zig) belongs to the
//! system-prompt parity package, not this one; wiring it in here would risk
//! duplicating/conflicting with that package's own in-flight edits.
//!
//! Pure module: entries in, a formatted string out. No allocation beyond the
//! one output buffer, no IO.

const std = @import("std");
const std_io = @import("std_io.zig");

/// One command as this algorithm needs it. Mirrors the reference's `Command`
/// shape narrowly (`isHidden`, `type`, `source`, `aliases`, `description`) --
/// only the fields the filter/format steps actually consult.
pub const CommandEntry = struct {
    name: []const u8,
    description: []const u8,
    aliases: []const []const u8 = &.{},
    /// Reference `isHidden`. Excluded unconditionally regardless of type/source.
    is_hidden: bool = false,
    /// Reference `type !== "prompt"`. Non-prompt commands (built-in `local`/
    /// `local-jsx` handlers, `scan`, etc.) always pass this half of the
    /// filter; only `type: "prompt"` commands need `is_prompt_from_builtin_
    /// or_bundled` to also be true.
    is_prompt_type: bool = false,
    /// Reference `source === "builtin" || source === "bundled"`. Only
    /// consulted when `is_prompt_type` is true (a user/plugin-installed
    /// prompt command has neither source and is excluded from this list,
    /// though it still shows in the interactive `/help` UI).
    is_prompt_from_builtin_or_bundled: bool = false,
};

fn passesFilter(e: CommandEntry) bool {
    if (e.is_hidden) return false;
    // r = e => e.type !== "prompt" || e.source === "builtin" || e.source === "bundled"
    if (!e.is_prompt_type) return true;
    return e.is_prompt_from_builtin_or_bundled;
}

/// Render the reference's exact `**Available commands (N in this build):**`
/// block: one `- /name (aliases: /a, /b): description` line per surviving
/// command, sorted alphabetically by name, aliases parenthetical omitted
/// when a command has none. Caller owns the returned slice.
pub fn renderAvailableCommands(allocator: std.mem.Allocator, entries: []const CommandEntry) ![]u8 {
    var kept: std.array_list.Managed(CommandEntry) = .init(allocator);
    defer kept.deinit();
    for (entries) |e| {
        if (passesFilter(e)) try kept.append(e);
    }
    std.mem.sort(CommandEntry, kept.items, {}, struct {
        fn lessThan(_: void, a: CommandEntry, b: CommandEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.print("**Available commands ({d} in this build):**", .{kept.items.len});
    for (kept.items) |e| {
        try w.writeAll("\n- /");
        try w.writeAll(e.name);
        if (e.aliases.len > 0) {
            try w.writeAll(" (aliases: ");
            for (e.aliases, 0..) |a, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll("/");
                try w.writeAll(a);
            }
            try w.writeAll(")");
        }
        try w.writeAll(": ");
        try w.writeAll(e.description);
    }
    return out.toOwnedSlice();
}

const testing = std.testing;

test "renderAvailableCommands: excludes hidden commands" {
    const allocator = testing.allocator;
    const entries = [_]CommandEntry{
        .{ .name = "clear", .description = "Clear the conversation" },
        .{ .name = "internal-debug", .description = "not for users", .is_hidden = true },
    };
    const out = try renderAvailableCommands(allocator, &entries);
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "/clear") != null);
    try testing.expect(std.mem.indexOf(u8, out, "internal-debug") == null);
    try testing.expect(std.mem.indexOf(u8, out, "(1 in this build)") != null);
}

test "renderAvailableCommands: excludes a user/plugin prompt command but keeps a bundled one" {
    const allocator = testing.allocator;
    const entries = [_]CommandEntry{
        .{ .name = "my-snippet", .description = "user-authored", .is_prompt_type = true, .is_prompt_from_builtin_or_bundled = false },
        .{ .name = "commit", .description = "bundled skill prompt", .is_prompt_type = true, .is_prompt_from_builtin_or_bundled = true },
        .{ .name = "help", .description = "Show help", .is_prompt_type = false },
    };
    const out = try renderAvailableCommands(allocator, &entries);
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "my-snippet") == null);
    try testing.expect(std.mem.indexOf(u8, out, "/commit: bundled skill prompt") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/help: Show help") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(2 in this build)") != null);
}

test "renderAvailableCommands: sorts alphabetically and formats aliases exactly" {
    const allocator = testing.allocator;
    const entries = [_]CommandEntry{
        .{ .name = "zap", .description = "zap it" },
        .{ .name = "agents", .description = "manage agents", .aliases = &.{"peers"} },
        .{ .name = "bug", .description = "report a bug", .aliases = &.{"share"} },
    };
    const out = try renderAvailableCommands(allocator, &entries);
    defer allocator.free(out);
    const expected =
        "**Available commands (3 in this build):**\n" ++
        "- /agents (aliases: /peers): manage agents\n" ++
        "- /bug (aliases: /share): report a bug\n" ++
        "- /zap: zap it";
    try testing.expectEqualStrings(expected, out);
}

test "renderAvailableCommands: multiple aliases join with a comma-space, no aliases omits the parenthetical" {
    const allocator = testing.allocator;
    const entries = [_]CommandEntry{
        .{ .name = "pause-memory", .description = "pause memory", .aliases = &.{ "memory-pause", "toggle-memory" } },
        .{ .name = "clear", .description = "clear conversation" },
    };
    const out = try renderAvailableCommands(allocator, &entries);
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "- /pause-memory (aliases: /memory-pause, /toggle-memory): pause memory") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- /clear: clear conversation") != null);
}

test "renderAvailableCommands: empty input renders a zero-count header with no lines" {
    const allocator = testing.allocator;
    const out = try renderAvailableCommands(allocator, &.{});
    defer allocator.free(out);
    try testing.expectEqualStrings("**Available commands (0 in this build):**", out);
}
