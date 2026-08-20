//! Skill data model + frontmatter parser (the foundation deep module for skill
//! parity with Claude Code, PRD Softorize/zcode#532). Kept as a leaf module so
//! the pure transforms (parse, allowed-tools parsing) are unit-testable in
//! isolation and other skill modules (listing, visibility) can depend on the
//! `SkillSpec` type without a dependency cycle through skills.zig.

const std = @import("std");
const frontmatter = @import("frontmatter.zig");

pub const SkillScope = enum { builtin, user, workspace, plugin, mcp };

/// Execution mode. `inline_skill` expands the skill into the current
/// conversation; `fork` runs it as an isolated synchronous sub-agent. The field
/// is named `inline_skill` because `inline` is a Zig keyword.
pub const SkillContext = enum { inline_skill, fork };

pub fn scopeName(scope: SkillScope) []const u8 {
    return switch (scope) {
        .builtin => "builtin",
        .user => "user",
        .workspace => "workspace",
        .plugin => "plugin",
        .mcp => "mcp",
    };
}

pub fn contextName(ctx: SkillContext) []const u8 {
    return switch (ctx) {
        .inline_skill => "inline",
        .fork => "fork",
    };
}

pub const SkillSpec = struct {
    name: []u8,
    description: []u8,
    /// `when-to-use` frontmatter; empty when absent. Surfaced in the awareness
    /// listing so the model knows when to reach for the skill.
    when_to_use: []u8,
    /// Body with frontmatter stripped (the instructions the model follows).
    prompt: []u8,
    scope: SkillScope,
    source_path: []u8,
    /// Tools auto-allowed while the skill runs (comma-separated frontmatter).
    allowed_tools: [][]u8,
    /// Named argument slots for `$foo` substitution (`arguments` frontmatter).
    arg_names: [][]u8,
    /// Per-skill overrides; empty string = inherit from session.
    model: []u8,
    effort: []u8,
    context: SkillContext,
    agent: []u8,
    /// Glob patterns; when non-empty the skill is visible only after a matching
    /// file is touched in the session.
    paths: [][]u8,
    user_invocable: bool,
    disable_model_invocation: bool,
    version: []u8,
    /// skills-13: alternate invocation names (comma-separated `aliases`
    /// frontmatter). `findByName` matches any alias case-insensitively, but the
    /// canonical `name` still wins on listing/sort. Empty list = no aliases.
    /// Mirrors the reference bundledSkills `aliases?` field (bundledSkills.ts:18,79).
    aliases: [][]u8,
    /// skills-11: the skill's `hooks:` frontmatter, stashed as an opaque JSON
    /// object string (the same shape settings.json `hooks` uses, e.g.
    /// `{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"./x.sh"}]}]}`).
    /// Empty string = no hooks. Stored opaque (not a value tree) so the spec
    /// stays a flat owned-string struct; the run path converts it to HookDefs
    /// at invoke time via `hooksSettingsJson` + `hook_config.parse`. Mirrors
    /// `agents.zig`'s `hooks_json` field and the reference's
    /// `parseHooksFromFrontmatter` (loadSkillsDir.ts:136-153).
    hooks_json: []u8,

    pub fn deinit(self: *SkillSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.when_to_use);
        allocator.free(self.prompt);
        allocator.free(self.source_path);
        allocator.free(self.model);
        allocator.free(self.effort);
        allocator.free(self.agent);
        allocator.free(self.version);
        allocator.free(self.hooks_json);
        freeStrList(allocator, self.allowed_tools);
        freeStrList(allocator, self.arg_names);
        freeStrList(allocator, self.paths);
        freeStrList(allocator, self.aliases);
    }
};

pub fn freeStrList(allocator: std.mem.Allocator, list: [][]u8) void {
    for (list) |s| allocator.free(s);
    allocator.free(list);
}

pub fn freeList(allocator: std.mem.Allocator, skills: []SkillSpec) void {
    for (skills) |*skill| skill.deinit(allocator);
    allocator.free(skills);
}

fn dupeStrList(allocator: std.mem.Allocator, list: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, list.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |s| allocator.free(s);
        allocator.free(out);
    }
    for (list, 0..) |s, i| {
        out[i] = try allocator.dupe(u8, s);
        filled = i + 1;
    }
    return out;
}

pub fn clone(allocator: std.mem.Allocator, skill: *const SkillSpec) !SkillSpec {
    return .{
        .name = try allocator.dupe(u8, skill.name),
        .description = try allocator.dupe(u8, skill.description),
        .when_to_use = try allocator.dupe(u8, skill.when_to_use),
        .prompt = try allocator.dupe(u8, skill.prompt),
        .scope = skill.scope,
        .source_path = try allocator.dupe(u8, skill.source_path),
        .allowed_tools = try dupeStrList(allocator, skill.allowed_tools),
        .arg_names = try dupeStrList(allocator, skill.arg_names),
        .model = try allocator.dupe(u8, skill.model),
        .effort = try allocator.dupe(u8, skill.effort),
        .context = skill.context,
        .agent = try allocator.dupe(u8, skill.agent),
        .paths = try dupeStrList(allocator, skill.paths),
        .user_invocable = skill.user_invocable,
        .disable_model_invocation = skill.disable_model_invocation,
        .version = try allocator.dupe(u8, skill.version),
        .aliases = try dupeStrList(allocator, skill.aliases),
        .hooks_json = try allocator.dupe(u8, skill.hooks_json),
    };
}

/// Construct a builtin skill spec with default field values. `aliases` is the
/// bundled skill's alternate-name list (empty for most builtins); it is duped
/// into the spec so the caller keeps ownership of its slice.
pub fn makeBuiltin(allocator: std.mem.Allocator, name: []const u8, description: []const u8, prompt: []const u8, aliases: []const []const u8) !SkillSpec {
    return .{
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, description),
        .when_to_use = try allocator.dupe(u8, ""),
        .prompt = try allocator.dupe(u8, prompt),
        .scope = .builtin,
        .source_path = try std.fmt.allocPrint(allocator, "<builtin:{s}>", .{name}),
        .allowed_tools = try allocator.alloc([]u8, 0),
        .arg_names = try allocator.alloc([]u8, 0),
        .model = try allocator.dupe(u8, ""),
        .effort = try allocator.dupe(u8, ""),
        .context = .inline_skill,
        .agent = try allocator.dupe(u8, ""),
        .paths = try allocator.alloc([]u8, 0),
        .user_invocable = true,
        .disable_model_invocation = false,
        .version = try allocator.dupe(u8, ""),
        .aliases = try dupeStrList(allocator, aliases),
        .hooks_json = try allocator.dupe(u8, ""),
    };
}

// ===========================================================================
// Parser (deep module #1) — raw SKILL.md -> fully-populated SkillSpec
// ===========================================================================

/// Parse a raw SKILL.md into a SkillSpec: extract frontmatter fields, strip the
/// frontmatter from the body, and apply defaults. Never fails on malformed
/// frontmatter -- it degrades to "no frontmatter" handling. The caller owns the
/// returned spec (call deinit).
pub fn parse(
    allocator: std.mem.Allocator,
    raw: []const u8,
    name: []const u8,
    scope: SkillScope,
    source_path: []const u8,
) !SkillSpec {
    if (frontmatter.extract(raw)) |block| {
        const fm = block.body;
        // name override from frontmatter, else the directory name.
        const fm_name = frontmatter.getValue(fm, "name");
        const eff_name = if (fm_name) |n| (if (n.len > 0) n else name) else name;

        return .{
            .name = try allocator.dupe(u8, eff_name),
            .description = try allocator.dupe(u8, descriptionFrom(fm) orelse name),
            .when_to_use = try allocator.dupe(u8, getEither(fm, "when-to-use", "whenToUse") orelse ""),
            .prompt = try allocator.dupe(u8, block.rest),
            .scope = scope,
            .source_path = try allocator.dupe(u8, source_path),
            .allowed_tools = try parseCommaList(allocator, getEither(fm, "allowed-tools", "allowedTools") orelse ""),
            .arg_names = try parseSpaceList(allocator, frontmatter.getValue(fm, "arguments") orelse ""),
            .model = try allocator.dupe(u8, frontmatter.getValue(fm, "model") orelse ""),
            .effort = try allocator.dupe(u8, frontmatter.getValue(fm, "effort") orelse ""),
            .context = parseContext(frontmatter.getValue(fm, "context")),
            .agent = try allocator.dupe(u8, frontmatter.getValue(fm, "agent") orelse ""),
            .paths = try parseCommaList(allocator, frontmatter.getValue(fm, "paths") orelse ""),
            .user_invocable = parseBool(getEither(fm, "user-invocable", "user_invocable"), true),
            .disable_model_invocation = parseBool(getEither(fm, "disable-model-invocation", "disableModelInvocation"), false),
            .version = try allocator.dupe(u8, frontmatter.getValue(fm, "version") orelse ""),
            .aliases = try parseCommaList(allocator, frontmatter.getValue(fm, "aliases") orelse ""),
            .hooks_json = try allocator.dupe(u8, hooksJsonFrom(fm)),
        };
    }

    // No frontmatter: whole file is the body, description from first line.
    return .{
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, firstLineDescription(raw) orelse name),
        .when_to_use = try allocator.dupe(u8, ""),
        .prompt = try allocator.dupe(u8, raw),
        .scope = scope,
        .source_path = try allocator.dupe(u8, source_path),
        .allowed_tools = try allocator.alloc([]u8, 0),
        .arg_names = try allocator.alloc([]u8, 0),
        .model = try allocator.dupe(u8, ""),
        .effort = try allocator.dupe(u8, ""),
        .context = .inline_skill,
        .agent = try allocator.dupe(u8, ""),
        .paths = try allocator.alloc([]u8, 0),
        .user_invocable = true,
        .disable_model_invocation = false,
        .version = try allocator.dupe(u8, ""),
        .aliases = try allocator.alloc([]u8, 0),
        .hooks_json = try allocator.dupe(u8, ""),
    };
}

fn getEither(fm: []const u8, key_a: []const u8, key_b: []const u8) ?[]const u8 {
    return frontmatter.getValue(fm, key_a) orelse frontmatter.getValue(fm, key_b);
}

/// Description from frontmatter, handling inline and `description: |` block
/// scalar forms. For a block scalar, returns the first non-empty indented line.
fn descriptionFrom(fm: []const u8) ?[]const u8 {
    const v = frontmatter.getValue(fm, "description") orelse return null;
    if (v.len == 0 or v[0] == '|' or v[0] == '>') {
        // Block scalar: scan for the description: line, then the first non-empty
        // following line.
        var lines = std.mem.splitScalar(u8, fm, '\n');
        var found = false;
        while (lines.next()) |line| {
            const tl = std.mem.trim(u8, line, " \t\r");
            if (!found) {
                if (std.mem.startsWith(u8, tl, "description:")) found = true;
                continue;
            }
            if (tl.len == 0) continue;
            return tl;
        }
        return null;
    }
    return v;
}

/// First non-empty line of a body with no frontmatter, markdown markers stripped.
fn firstLineDescription(raw: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n#>-*");
        if (trimmed.len == 0) continue;
        return trimmed;
    }
    return null;
}

fn parseContext(v: ?[]const u8) SkillContext {
    const s = v orelse return .inline_skill;
    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, s, " \t"), "fork")) return .fork;
    return .inline_skill;
}

/// skills-11: extract the skill's `hooks:` frontmatter value. zcode's
/// frontmatter parser is flat-key only (no nested YAML), so a skill declares
/// its hooks as a single-line JSON object after `hooks:` -- the same shape the
/// settings.json `hooks` map uses. Returns the raw JSON object slice, or "" when
/// the field is absent or not a JSON object. The slice aliases into `fm`; the
/// caller dupes it. Only the JSON-object form is supported (a constrained format
/// in place of a YAML sub-parser, per the skills-11 footgun note); a non-`{`
/// value degrades to "" rather than faulting.
fn hooksJsonFrom(fm: []const u8) []const u8 {
    const v = frontmatter.getValue(fm, "hooks") orelse return "";
    const t = std.mem.trim(u8, v, " \t\r");
    if (t.len == 0 or t[0] != '{') return "";
    return t;
}

/// skills-11: wrap a skill's opaque `hooks_json` into a settings-shaped object
/// (`{"hooks": <obj>}`) that `hook_config.parse` consumes directly, so the skill
/// run path reuses the existing hook parser/dispatch instead of a bespoke one.
/// Returns null when the skill declares no hooks. The caller owns the returned
/// slice and must free it.
pub fn hooksSettingsJson(allocator: std.mem.Allocator, spec: *const SkillSpec) !?[]u8 {
    if (spec.hooks_json.len == 0) return null;
    return try std.fmt.allocPrint(allocator, "{{\"hooks\":{s}}}", .{spec.hooks_json});
}

// ===========================================================================
// Skill model override resolution (skills-10)
// ===========================================================================

/// Resolve a skill's `model:` frontmatter against the session's active model.
///
/// Returns null (no override) when `skill_model` is empty or case-insensitively
/// equals "inherit" -- both mean "keep whatever the session is using". Mirrors
/// the reference's `model:'inherit'` -> undefined handling
/// (loadSkillsDir.ts:221-235) and `resolveSkillModelOverride`
/// (SkillTool.ts:808-821).
///
/// Otherwise returns a freshly-allocated copy of the override. When the active
/// session model carries the `[1m]` (1-million-token context) suffix and the
/// skill's override does not already carry any `[...]` suffix, the `[1m]` suffix
/// is preserved (e.g. `model: opus` on an `opus[1m]` session yields `opus[1m]`).
/// The caller owns the returned slice and must free it.
pub fn resolveModelOverride(
    allocator: std.mem.Allocator,
    skill_model: []const u8,
    session_model: []const u8,
) !?[]u8 {
    const trimmed = std.mem.trim(u8, skill_model, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "inherit")) return null;

    // Carry the session's [1m] suffix forward only when the override does not
    // already specify its own bracketed suffix.
    const override_has_suffix = std.mem.indexOfScalar(u8, trimmed, '[') != null;
    if (!override_has_suffix and std.mem.endsWith(u8, session_model, "[1m]")) {
        return try std.fmt.allocPrint(allocator, "{s}[1m]", .{trimmed});
    }
    return try allocator.dupe(u8, trimmed);
}

// ===========================================================================
// Skill-tool permission gating: safe-properties auto-allow (skills-02)
// ===========================================================================

/// True when a skill declares ONLY "safe" frontmatter properties and therefore
/// may run without consulting the permission engine (the benign-skill
/// auto-allow that keeps zcode's bundled skills running prompt-free). Mirrors
/// the reference `SAFE_SKILL_PROPERTIES` allowlist + `skillHasOnlySafeProperties`
/// (SkillTool.ts:871-933).
///
/// The safe set is: name, description, when-to-use, version, user-invocable,
/// paths. A skill is UNSAFE (returns false) if it sets a meaningful value for
/// any property outside that set: a non-empty `allowed-tools` list, a non-empty
/// `agent`, a non-empty `model`, a non-empty `effort`, or `context: fork`. New
/// or unreviewed properties default to unsafe by being added to this check as
/// they are introduced (e.g. `hooks` once skills-11 lands).
pub fn hasOnlySafeProperties(spec: *const SkillSpec) bool {
    if (spec.allowed_tools.len > 0) return false;
    if (spec.agent.len > 0) return false;
    if (spec.model.len > 0) return false;
    if (spec.effort.len > 0) return false;
    if (spec.context == .fork) return false;
    // skills-11: declaring hooks runs author-supplied commands while the skill
    // is active, so a hooks block makes the skill unsafe (must consult the
    // permission engine rather than auto-allow).
    if (spec.hooks_json.len > 0) return false;
    return true;
}

// ===========================================================================
// Alias matching (skills-13)
// ===========================================================================

/// True when `requested` matches the skill's canonical name or any of its
/// aliases, case-insensitively. The canonical name is checked first so a
/// canonical-name hit always wins. `findByName` uses this; kept pure for unit
/// testing. Mirrors the reference's alias-aware lookup (bundledSkills.ts:79).
pub fn matchesNameOrAlias(spec: *const SkillSpec, requested: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(spec.name, requested)) return true;
    for (spec.aliases) |alias| {
        if (std.ascii.eqlIgnoreCase(alias, requested)) return true;
    }
    return false;
}

fn parseBool(v: ?[]const u8, default: bool) bool {
    const s = std.mem.trim(u8, v orelse return default, " \t");
    if (s.len == 0) return default;
    if (std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1") or std.ascii.eqlIgnoreCase(s, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(s, "false") or std.mem.eql(u8, s, "0") or std.ascii.eqlIgnoreCase(s, "no")) return false;
    return default;
}

// ===========================================================================
// allowed-tools / list parsing (deep module #2)
// ===========================================================================

/// Parse a comma-separated frontmatter value into an owned list of trimmed,
/// non-empty entries. Handles the `allowed-tools` and `paths` fields. The YAML
/// inline-list/block-sequence forms are out of scope (flat frontmatter only).
pub fn parseCommaList(allocator: std.mem.Allocator, value: []const u8) ![][]u8 {
    return splitList(allocator, value, ',');
}

/// Parse a whitespace-separated value into an owned list (for `arguments`).
pub fn parseSpaceList(allocator: std.mem.Allocator, value: []const u8) ![][]u8 {
    var list = std.array_list.Managed([]u8).init(allocator);
    errdefer freeStrListManaged(allocator, &list);
    var it = std.mem.tokenizeAny(u8, value, " \t");
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (t.len == 0) continue;
        try list.append(try allocator.dupe(u8, t));
    }
    return list.toOwnedSlice();
}

fn splitList(allocator: std.mem.Allocator, value: []const u8, sep: u8) ![][]u8 {
    var list = std.array_list.Managed([]u8).init(allocator);
    errdefer freeStrListManaged(allocator, &list);
    var it = std.mem.splitScalar(u8, value, sep);
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (t.len == 0) continue;
        try list.append(try allocator.dupe(u8, t));
    }
    return list.toOwnedSlice();
}

fn freeStrListManaged(allocator: std.mem.Allocator, list: *std.array_list.Managed([]u8)) void {
    for (list.items) |s| allocator.free(s);
    list.deinit();
}

// ===========================================================================
// MCP prompt -> skill spec mapper (deep module #5)
// ===========================================================================

/// Map an MCP server prompt into a SkillSpec (scope .mcp). The body is empty --
/// it is fetched from the server at invocation time; `source_path` encodes the
/// routing target as "mcp:<server>:<prompt>" so the run path can call
/// mcp_prompt_get. Pure given the prompt metadata.
pub fn mcpPromptToSkill(
    allocator: std.mem.Allocator,
    server: []const u8,
    prompt_name: []const u8,
    description: []const u8,
) !SkillSpec {
    return .{
        .name = try allocator.dupe(u8, prompt_name),
        .description = try allocator.dupe(u8, description),
        .when_to_use = try allocator.dupe(u8, ""),
        .prompt = try allocator.dupe(u8, ""),
        .scope = .mcp,
        .source_path = try std.fmt.allocPrint(allocator, "mcp:{s}:{s}", .{ server, prompt_name }),
        .allowed_tools = try allocator.alloc([]u8, 0),
        .arg_names = try allocator.alloc([]u8, 0),
        .model = try allocator.dupe(u8, ""),
        .effort = try allocator.dupe(u8, ""),
        .context = .inline_skill,
        .agent = try allocator.dupe(u8, ""),
        .paths = try allocator.alloc([]u8, 0),
        .user_invocable = true,
        .disable_model_invocation = false,
        .version = try allocator.dupe(u8, ""),
        .aliases = try allocator.alloc([]u8, 0),
        .hooks_json = try allocator.dupe(u8, ""),
    };
}

/// Parse the "mcp:<server>:<prompt>" routing target back out of an mcp skill's
/// source_path. Returns null if the path is not an mcp routing target.
pub fn mcpRouteFromSource(source_path: []const u8) ?struct { server: []const u8, prompt: []const u8 } {
    if (!std.mem.startsWith(u8, source_path, "mcp:")) return null;
    const rest = source_path["mcp:".len..];
    const sep = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    return .{ .server = rest[0..sep], .prompt = rest[sep + 1 ..] };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "parse populates fields and strips frontmatter from body" {
    const raw =
        "---\nname: committer\ndescription: Make a commit\nwhen-to-use: when changes are staged\n" ++
        "allowed-tools: GitStatus, Bash\narguments: message scope\nmodel: opus\neffort: high\n" ++
        "context: fork\nagent: Bash\nuser-invocable: false\nversion: 2\n---\n# Body\nDo the thing.\n";
    var spec = try parse(testing.allocator, raw, "dirname", .user, "/x/SKILL.md");
    defer spec.deinit(testing.allocator);

    try testing.expectEqualStrings("committer", spec.name); // frontmatter name overrides dir
    try testing.expectEqualStrings("Make a commit", spec.description);
    try testing.expectEqualStrings("when changes are staged", spec.when_to_use);
    try testing.expectEqual(@as(usize, 2), spec.allowed_tools.len);
    try testing.expectEqualStrings("GitStatus", spec.allowed_tools[0]);
    try testing.expectEqualStrings("Bash", spec.allowed_tools[1]);
    try testing.expectEqual(@as(usize, 2), spec.arg_names.len);
    try testing.expectEqualStrings("message", spec.arg_names[0]);
    try testing.expectEqualStrings("opus", spec.model);
    try testing.expectEqualStrings("high", spec.effort);
    try testing.expectEqual(SkillContext.fork, spec.context);
    try testing.expectEqualStrings("Bash", spec.agent);
    try testing.expect(!spec.user_invocable);
    try testing.expectEqualStrings("2", spec.version);
    // Body must NOT contain the frontmatter.
    try testing.expect(std.mem.indexOf(u8, spec.prompt, "name: committer") == null);
    try testing.expect(std.mem.indexOf(u8, spec.prompt, "Do the thing.") != null);
}

test "parse handles no frontmatter" {
    var spec = try parse(testing.allocator, "# Title\n\nbody text\n", "mydir", .workspace, "/p");
    defer spec.deinit(testing.allocator);
    try testing.expectEqualStrings("mydir", spec.name);
    try testing.expectEqualStrings("Title", spec.description);
    try testing.expect(spec.user_invocable);
    try testing.expectEqual(SkillContext.inline_skill, spec.context);
    try testing.expectEqual(@as(usize, 0), spec.allowed_tools.len);
}

test "parse reads block-scalar description" {
    const raw = "---\nname: z\ndescription: |\n  First line of desc.\n  Second line.\n---\nbody\n";
    var spec = try parse(testing.allocator, raw, "z", .user, "/p");
    defer spec.deinit(testing.allocator);
    try testing.expectEqualStrings("First line of desc.", spec.description);
}

test "parseCommaList trims and drops empties" {
    const list = try parseCommaList(testing.allocator, " Read ,, Write,Bash ");
    defer freeStrList(testing.allocator, list);
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqualStrings("Read", list[0]);
    try testing.expectEqualStrings("Write", list[1]);
    try testing.expectEqualStrings("Bash", list[2]);

    const empty = try parseCommaList(testing.allocator, "");
    defer freeStrList(testing.allocator, empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "mcpPromptToSkill maps and round-trips its route" {
    var spec = try mcpPromptToSkill(testing.allocator, "weather", "forecast", "Get a forecast");
    defer spec.deinit(testing.allocator);
    try testing.expectEqualStrings("forecast", spec.name);
    try testing.expectEqualStrings("Get a forecast", spec.description);
    try testing.expectEqual(SkillScope.mcp, spec.scope);
    try testing.expectEqualStrings("mcp:weather:forecast", spec.source_path);

    const route = mcpRouteFromSource(spec.source_path).?;
    try testing.expectEqualStrings("weather", route.server);
    try testing.expectEqualStrings("forecast", route.prompt);
    try testing.expect(mcpRouteFromSource("/local/SKILL.md") == null);
}

test "resolveModelOverride: explicit, inherit, empty, and [1m] carry-over" {
    const alloc = testing.allocator;

    // Explicit override on a plain session model -> override verbatim.
    {
        const r = try resolveModelOverride(alloc, "sonnet", "opus");
        defer if (r) |s| alloc.free(s);
        try testing.expect(r != null);
        try testing.expectEqualStrings("sonnet", r.?);
    }

    // [1m] carry-over: override gains the session's [1m] suffix.
    {
        const r = try resolveModelOverride(alloc, "opus", "opus[1m]");
        defer if (r) |s| alloc.free(s);
        try testing.expect(r != null);
        try testing.expectEqualStrings("opus[1m]", r.?);
    }

    // Override already carrying its own suffix is not double-suffixed.
    {
        const r = try resolveModelOverride(alloc, "sonnet[1m]", "opus[1m]");
        defer if (r) |s| alloc.free(s);
        try testing.expect(r != null);
        try testing.expectEqualStrings("sonnet[1m]", r.?);
    }

    // "inherit" (any case) -> no override.
    {
        const r = try resolveModelOverride(alloc, "inherit", "opus");
        try testing.expect(r == null);
        const r2 = try resolveModelOverride(alloc, "Inherit", "opus[1m]");
        try testing.expect(r2 == null);
    }

    // Empty / whitespace-only -> no override.
    {
        const r = try resolveModelOverride(alloc, "", "opus");
        try testing.expect(r == null);
        const r2 = try resolveModelOverride(alloc, "   ", "opus");
        try testing.expect(r2 == null);
    }
}

test "hasOnlySafeProperties: name/description-only safe; allowed-tools and fork unsafe" {
    const alloc = testing.allocator;

    // (a-true) A name/description-only skill is safe.
    {
        const raw = "---\nname: doc\ndescription: just docs\nwhen-to-use: anytime\nversion: 1\nuser-invocable: true\npaths: *.zig\n---\nbody\n";
        var spec = try parse(alloc, raw, "doc", .workspace, "/p");
        defer spec.deinit(alloc);
        try testing.expect(hasOnlySafeProperties(&spec));
    }

    // (a-false) allowed-tools makes it unsafe.
    {
        const raw = "---\nname: t\ndescription: d\nallowed-tools: Bash\n---\nbody\n";
        var spec = try parse(alloc, raw, "t", .workspace, "/p");
        defer spec.deinit(alloc);
        try testing.expect(!hasOnlySafeProperties(&spec));
    }

    // (a-false) context: fork makes it unsafe.
    {
        const raw = "---\nname: f\ndescription: d\ncontext: fork\n---\nbody\n";
        var spec = try parse(alloc, raw, "f", .workspace, "/p");
        defer spec.deinit(alloc);
        try testing.expect(!hasOnlySafeProperties(&spec));
    }

    // model / effort / agent each make it unsafe.
    {
        const raw = "---\nname: m\ndescription: d\nmodel: opus\n---\nbody\n";
        var spec = try parse(alloc, raw, "m", .workspace, "/p");
        defer spec.deinit(alloc);
        try testing.expect(!hasOnlySafeProperties(&spec));
    }
    {
        const raw = "---\nname: e\ndescription: d\neffort: high\n---\nbody\n";
        var spec = try parse(alloc, raw, "e", .workspace, "/p");
        defer spec.deinit(alloc);
        try testing.expect(!hasOnlySafeProperties(&spec));
    }
    {
        const raw = "---\nname: a\ndescription: d\nagent: Bash\n---\nbody\n";
        var spec = try parse(alloc, raw, "a", .workspace, "/p");
        defer spec.deinit(alloc);
        try testing.expect(!hasOnlySafeProperties(&spec));
    }

    // A builtin made via makeBuiltin (no overrides) is safe.
    {
        var spec = try makeBuiltin(alloc, "loop", "loop a prompt", "do it", &.{});
        defer spec.deinit(alloc);
        try testing.expect(hasOnlySafeProperties(&spec));
    }
}

test "skills-11: parse extracts a single-line JSON hooks block; absent yields empty" {
    const alloc = testing.allocator;

    // A skill declaring a PreToolUse command hook as a single-line JSON object.
    {
        const raw =
            "---\nname: guarded\ndescription: d\n" ++
            "hooks: {\"PreToolUse\":[{\"matcher\":\"*\",\"hooks\":[{\"type\":\"command\",\"command\":\"./pre.sh\"}]}]}\n" ++
            "---\nbody\n";
        var spec = try parse(alloc, raw, "guarded", .workspace, "/p");
        defer spec.deinit(alloc);
        try testing.expect(spec.hooks_json.len > 0);
        try testing.expect(std.mem.startsWith(u8, spec.hooks_json, "{"));
        try testing.expect(std.mem.indexOf(u8, spec.hooks_json, "PreToolUse") != null);
        // Declaring hooks makes the skill non-safe-only (it runs author commands).
        try testing.expect(!hasOnlySafeProperties(&spec));
    }

    // A skill with no hooks key -> empty hooks_json, still safe-only.
    {
        const raw = "---\nname: plain\ndescription: d\n---\nbody\n";
        var spec = try parse(alloc, raw, "plain", .workspace, "/p");
        defer spec.deinit(alloc);
        try testing.expectEqualStrings("", spec.hooks_json);
        try testing.expect(hasOnlySafeProperties(&spec));
    }

    // A non-object hooks value degrades to empty rather than faulting.
    {
        const raw = "---\nname: bad\ndescription: d\nhooks: notjson\n---\nbody\n";
        var spec = try parse(alloc, raw, "bad", .workspace, "/p");
        defer spec.deinit(alloc);
        try testing.expectEqualStrings("", spec.hooks_json);
    }
}

test "skills-11: hooksSettingsJson wraps the block and parses via hook_config" {
    const alloc = testing.allocator;
    const hook_config = @import("hook_config.zig");

    const raw =
        "---\nname: guarded\ndescription: d\n" ++
        "hooks: {\"PreToolUse\":[{\"matcher\":\"Bash(*)\",\"hooks\":[{\"type\":\"command\",\"command\":\"./pre.sh\",\"timeout\":3}]}]}\n" ++
        "---\nbody\n";
    var spec = try parse(alloc, raw, "guarded", .workspace, "/p");
    defer spec.deinit(alloc);

    const settings = (try hooksSettingsJson(alloc, &spec)).?;
    defer alloc.free(settings);
    try testing.expect(std.mem.startsWith(u8, settings, "{\"hooks\":"));

    // The wrapped settings object parses into a HookDef via the existing engine.
    var parsed = try hook_config.parse(alloc, settings);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.defs.len);
    try testing.expectEqualStrings("Bash(*)", parsed.defs[0].matcher);
    try testing.expectEqualStrings("./pre.sh", parsed.defs[0].body);
    try testing.expectEqual(@as(?u32, 3), parsed.defs[0].timeout_s);

    // A hooks-free skill yields null (no settings to wrap).
    var plain = try parse(alloc, "---\nname: p\ndescription: d\n---\nb\n", "p", .workspace, "/p");
    defer plain.deinit(alloc);
    try testing.expect((try hooksSettingsJson(alloc, &plain)) == null);
}

test "skills-11: clone round-trips hooks_json" {
    const alloc = testing.allocator;
    const raw =
        "---\nname: g\ndescription: d\n" ++
        "hooks: {\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"./s.sh\"}]}]}\n" ++
        "---\nb\n";
    var spec = try parse(alloc, raw, "g", .workspace, "/p");
    defer spec.deinit(alloc);
    var copy = try clone(alloc, &spec);
    defer copy.deinit(alloc);
    try testing.expectEqualStrings(spec.hooks_json, copy.hooks_json);
}

test "skills-13: parse reads the aliases comma list; matchesNameOrAlias matches canonical name and any alias" {
    const alloc = testing.allocator;

    // A skill declaring two aliases.
    const raw = "---\nname: commit\ndescription: make a commit\naliases: cmt, ci\n---\nbody\n";
    var spec = try parse(alloc, raw, "commit", .workspace, "/p");
    defer spec.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), spec.aliases.len);
    try testing.expectEqualStrings("cmt", spec.aliases[0]);
    try testing.expectEqualStrings("ci", spec.aliases[1]);

    // Canonical name and either alias match (case-insensitively); a stranger does not.
    try testing.expect(matchesNameOrAlias(&spec, "commit"));
    try testing.expect(matchesNameOrAlias(&spec, "COMMIT"));
    try testing.expect(matchesNameOrAlias(&spec, "ci"));
    try testing.expect(matchesNameOrAlias(&spec, "CMT"));
    try testing.expect(!matchesNameOrAlias(&spec, "deploy"));

    // Declaring aliases is a safe property (it does not run code).
    try testing.expect(hasOnlySafeProperties(&spec));
}

test "skills-13: a skill with no aliases yields an empty list and matches only its name" {
    const alloc = testing.allocator;
    var spec = try parse(alloc, "---\nname: plain\ndescription: d\n---\nb\n", "plain", .workspace, "/p");
    defer spec.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), spec.aliases.len);
    try testing.expect(matchesNameOrAlias(&spec, "plain"));
    try testing.expect(!matchesNameOrAlias(&spec, "x"));
}

test "skills-13: makeBuiltin stores aliases and clone round-trips them" {
    const alloc = testing.allocator;
    const aliases = [_][]const u8{ "cmt", "ci" };
    var spec = try makeBuiltin(alloc, "commit", "make a commit", "do it", &aliases);
    defer spec.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), spec.aliases.len);
    try testing.expect(matchesNameOrAlias(&spec, "ci"));

    var copy = try clone(alloc, &spec);
    defer copy.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), copy.aliases.len);
    try testing.expectEqualStrings("cmt", copy.aliases[0]);
    try testing.expectEqualStrings("ci", copy.aliases[1]);
}

test "parseBool and parseContext defaults" {
    try testing.expect(parseBool("true", false));
    try testing.expect(!parseBool("no", true));
    try testing.expect(parseBool(null, true));
    try testing.expectEqual(SkillContext.fork, parseContext("fork"));
    try testing.expectEqual(SkillContext.inline_skill, parseContext(null));
    try testing.expectEqual(SkillContext.inline_skill, parseContext("inline"));
}
