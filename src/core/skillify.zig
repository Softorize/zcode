//! skillify (skills-07): deterministic SKILL.md assembly for the authoring
//! flow. The interview itself is model-driven (the `skillify` bundled skill in
//! bundled_skills.zig drives it through AskUserQuestion + Write); this module is
//! the small deterministic piece that turns a set of chosen fields into a valid
//! SKILL.md whose frontmatter always parses cleanly with skill_types.parse.
//!
//! Reference: claude-code-main/src/skills/bundled/skillify.ts (the structured
//! SKILL.md write at the end of the interview). zcode ships a local equivalent.
//!
//! This module is PURE: no file IO, no rt singleton. Output is an owned string
//! the caller frees.

const std = @import("std");
const std_io = @import("std_io.zig");
const skill_types = @import("skill_types.zig");

/// The fields a skillify interview collects, in the order they appear in the
/// emitted frontmatter. Only `name`, `description`, and `body` are required to
/// produce a well-formed SKILL.md; the rest are optional and omitted from the
/// frontmatter when empty (so the generated file never carries a meaningless
/// `model:` or `context:` line that would make the skill fail
/// hasOnlySafeProperties for no reason).
pub const SkillMdFields = struct {
    name: []const u8,
    description: []const u8,
    when_to_use: []const u8 = "",
    /// Comma-joined already (e.g. "Read, Grep, Bash"); emitted verbatim as the
    /// `allowed-tools:` value when non-empty.
    allowed_tools: []const u8 = "",
    /// "inline" or "fork"; emitted as `context:` only when "fork" (inline is the
    /// default, so omitting it keeps the file minimal and safe-by-default).
    context: skill_types.SkillContext = .inline_skill,
    /// Comma-joined glob patterns for conditional activation; emitted as
    /// `paths:` when non-empty.
    paths: []const u8 = "",
    /// The instruction body that follows the frontmatter.
    body: []const u8,
};

/// Render canonical SKILL.md text from the chosen fields. The frontmatter is
/// always a `---`-delimited block so the result parses through
/// skill_types.parse without degrading to the no-frontmatter path.
///
/// Frontmatter values are sanitized to single lines: any embedded newline or
/// carriage return in name/description/when-to-use is collapsed to a space, and
/// a stray `---` token in a value would break the block, so those are neutered
/// to en-spaced hyphens. The caller owns the returned slice.
pub fn renderSkillMd(allocator: std.mem.Allocator, fields: SkillMdFields) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("---\n");

    const name = try sanitizeValue(allocator, fields.name);
    defer allocator.free(name);
    try w.print("name: {s}\n", .{name});

    const desc = try sanitizeValue(allocator, fields.description);
    defer allocator.free(desc);
    try w.print("description: {s}\n", .{desc});

    if (fields.when_to_use.len > 0) {
        const wtu = try sanitizeValue(allocator, fields.when_to_use);
        defer allocator.free(wtu);
        try w.print("when-to-use: {s}\n", .{wtu});
    }

    if (fields.allowed_tools.len > 0) {
        const tools = try sanitizeValue(allocator, fields.allowed_tools);
        defer allocator.free(tools);
        try w.print("allowed-tools: {s}\n", .{tools});
    }

    if (fields.context == .fork) {
        try w.writeAll("context: fork\n");
    }

    if (fields.paths.len > 0) {
        const p = try sanitizeValue(allocator, fields.paths);
        defer allocator.free(p);
        try w.print("paths: {s}\n", .{p});
    }

    try w.writeAll("---\n");

    // Separate the frontmatter from the body with a blank line, then the body
    // verbatim. Guarantee a trailing newline so the file is well-formed.
    try w.writeAll("\n");
    try w.writeAll(fields.body);
    if (fields.body.len == 0 or fields.body[fields.body.len - 1] != '\n') {
        try w.writeAll("\n");
    }

    return out.toOwnedSlice();
}

/// Collapse any run of whitespace (newlines, CRs, tabs, spaces) to a single
/// space so the value stays on one line and the document stays parseable, then
/// trim the ends. A literal "---" inside a value cannot open a new frontmatter
/// fence (a fence must begin a line), so it needs no special handling once
/// newlines are collapsed. Caller owns the result.
fn sanitizeValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, value.len);
    errdefer allocator.free(buf);
    var i: usize = 0;
    var prev_ws = false;
    for (value) |c| {
        const is_ws = c == ' ' or c == '\t' or c == '\n' or c == '\r';
        if (is_ws) {
            if (!prev_ws) {
                buf[i] = ' ';
                i += 1;
            }
            prev_ws = true;
        } else {
            buf[i] = c;
            i += 1;
            prev_ws = false;
        }
    }
    const trimmed = std.mem.trim(u8, buf[0..i], " ");
    // Shrink in place: trim returns a sub-slice, so move it to the front before
    // realloc so the returned slice owns exactly its bytes.
    if (trimmed.ptr != buf.ptr) {
        std.mem.copyForwards(u8, buf[0..trimmed.len], trimmed);
    }
    return allocator.realloc(buf, trimmed.len);
}

const testing = std.testing;

test "skillify renderSkillMd round-trips through parse for supported fields" {
    const alloc = testing.allocator;
    const fields = SkillMdFields{
        .name = "deploy-frontend",
        .description = "Deploy the frontend to staging",
        .when_to_use = "when a frontend change is ready to ship",
        .allowed_tools = "Bash, Read",
        .context = .fork,
        .paths = "web/*.tsx, web/*.ts",
        .body = "1. Build the bundle.\n2. Upload to the bucket.\n3. Invalidate the CDN.",
    };

    const md = try renderSkillMd(alloc, fields);
    defer alloc.free(md);

    // Valid frontmatter: starts with the fence.
    try testing.expect(std.mem.startsWith(u8, md, "---\n"));

    var spec = try skill_types.parse(alloc, md, "deploy-frontend", .workspace, "/p/SKILL.md");
    defer spec.deinit(alloc);

    try testing.expectEqualStrings("deploy-frontend", spec.name);
    try testing.expectEqualStrings("Deploy the frontend to staging", spec.description);
    try testing.expectEqualStrings("when a frontend change is ready to ship", spec.when_to_use);
    try testing.expectEqual(@as(usize, 2), spec.allowed_tools.len);
    try testing.expectEqualStrings("Bash", spec.allowed_tools[0]);
    try testing.expectEqualStrings("Read", spec.allowed_tools[1]);
    try testing.expectEqual(skill_types.SkillContext.fork, spec.context);
    try testing.expectEqual(@as(usize, 2), spec.paths.len);
    try testing.expectEqualStrings("web/*.tsx", spec.paths[0]);
    try testing.expectEqualStrings("web/*.ts", spec.paths[1]);
    // The body survives, frontmatter stripped.
    try testing.expect(std.mem.indexOf(u8, spec.prompt, "Build the bundle.") != null);
    try testing.expect(std.mem.indexOf(u8, spec.prompt, "name: deploy-frontend") == null);
}

test "skillify renderSkillMd omits optional fields when empty (minimal, safe)" {
    const alloc = testing.allocator;
    const fields = SkillMdFields{
        .name = "notes",
        .description = "Just take notes",
        .body = "Write notes to the scratchpad.",
    };

    const md = try renderSkillMd(alloc, fields);
    defer alloc.free(md);

    // Minimal file: no optional frontmatter lines emitted.
    try testing.expect(std.mem.indexOf(u8, md, "when-to-use:") == null);
    try testing.expect(std.mem.indexOf(u8, md, "allowed-tools:") == null);
    try testing.expect(std.mem.indexOf(u8, md, "context:") == null);
    try testing.expect(std.mem.indexOf(u8, md, "paths:") == null);

    var spec = try skill_types.parse(alloc, md, "notes", .user, "/p/SKILL.md");
    defer spec.deinit(alloc);
    try testing.expectEqualStrings("notes", spec.name);
    try testing.expectEqualStrings("Just take notes", spec.description);
    try testing.expectEqual(skill_types.SkillContext.inline_skill, spec.context);
    // An inline, name/description-only skill is safe (no permission prompt).
    try testing.expect(skill_types.hasOnlySafeProperties(&spec));
}

test "skillify renderSkillMd collapses embedded newlines in values" {
    const alloc = testing.allocator;
    const fields = SkillMdFields{
        .name = "x",
        .description = "line one\nline two\r\nline three",
        .body = "do it",
    };

    const md = try renderSkillMd(alloc, fields);
    defer alloc.free(md);

    var spec = try skill_types.parse(alloc, md, "x", .user, "/p");
    defer spec.deinit(alloc);
    // The description is a single line, no raw newline leaked into frontmatter.
    try testing.expectEqualStrings("line one line two line three", spec.description);
}
