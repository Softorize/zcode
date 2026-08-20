const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const paths = @import("paths.zig");
const plugins_mod = @import("plugins.zig");

pub const StyleScope = enum {
    builtin,
    // styles-onboarding-02: plugin-provided output styles sit at plugin
    // priority, between builtin and user (builtin < plugin < user < workspace).
    plugin,
    user,
    workspace,
};

pub const OutputStyle = struct {
    name: []u8,
    description: []u8,
    prompt: []u8,
    scope: StyleScope,
    source_path: []u8,
    /// styles-onboarding-01: when true, the base "Doing tasks" coding section
    /// stays in the system prompt (the style layers on top of coding-agent
    /// behavior). When false, the style fully replaces it and the base section
    /// is omitted. The default style and the built-in Explanatory/Learning
    /// styles set this true; custom styles default to false unless their
    /// frontmatter sets `keep-coding-instructions: true`.
    keep_coding_instructions: bool = false,
    /// styles-onboarding-02: a plugin style with `force-for-plugin: true` is
    /// auto-selected regardless of the user's configured output_style. Only
    /// meaningful for `scope == .plugin`; always false elsewhere.
    force_for_plugin: bool = false,

    pub fn deinit(self: *OutputStyle, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.prompt);
        allocator.free(self.source_path);
    }
};

const BuiltinStyle = struct {
    name: []const u8,
    description: []const u8,
    prompt: []const u8,
    /// styles-onboarding-01: keep the base coding section for this builtin.
    /// `default` keeps it (base behavior); Explanatory/Learning keep it (they
    /// layer on top); Investigative is a tone overlay so it keeps it too.
    keep_coding_instructions: bool = true,
};

// Shared "Insights" tail used by both Explanatory and Learning styles.
// Ported from claude-code-main/src/constants/outputStyles.ts
// EXPLANATORY_FEATURE_PROMPT. The star + horizontal-rule visual is how
// Claude Code signals "this is an educational aside, not direct output"
// -- if we change the glyphs or rule width the model reliably wraps
// them differently, so keep the bytes verbatim.
const EXPLANATORY_FEATURE_PROMPT =
    \\
    \\## Insights
    \\In order to encourage learning, before and after writing code, always provide brief educational explanations about implementation choices using (with backticks):
    \\"`✶ Insight ─────────────────────────────────────`
    \\[2-3 key educational points]
    \\`─────────────────────────────────────────────────`"
    \\
    \\These insights should be included in the conversation, not in the codebase. You should generally focus on interesting insights that are specific to the codebase or the code you just wrote, rather than general programming concepts.
;

const builtin_styles = [_]BuiltinStyle{
    .{
        .name = "default",
        .description = "Default concise execution-first coding-agent style.",
        .prompt = "",
    },
    .{
        .name = "explanatory",
        .description = "Claude explains its implementation choices and codebase patterns.",
        .prompt =
        \\You are an interactive CLI tool that helps users with software engineering tasks. In addition to software engineering tasks, you should provide educational insights about the codebase along the way.
        \\
        \\You should be clear and educational, providing helpful explanations while remaining focused on the task. Balance educational content with task completion. When providing insights, you may exceed typical length constraints, but remain focused and relevant.
        \\
        \\# Explanatory Style Active
        ++ EXPLANATORY_FEATURE_PROMPT,
    },
    .{
        .name = "learning",
        .description = "Claude pauses and asks you to write small pieces of code for hands-on practice.",
        .prompt =
        \\You are an interactive CLI tool that helps users with software engineering tasks. In addition to software engineering tasks, you should help users learn more about the codebase through hands-on practice and educational insights.
        \\
        \\You should be collaborative and encouraging. Balance task completion with learning by requesting user input for meaningful design decisions while handling routine implementation yourself.
        \\
        \\# Learning Style Active
        \\## Requesting Human Contributions
        \\In order to encourage learning, ask the human to contribute 2-10 line code pieces when generating 20+ lines involving:
        \\- Design decisions (error handling, data structures)
        \\- Business logic with multiple valid approaches
        \\- Key algorithms or interface definitions
        \\
        \\**TodoList Integration**: If using a TodoList for the overall task, include a specific todo item like "Request human input on [specific decision]" when planning to request human input. This ensures proper task tracking. Note: TodoList is not required for all tasks.
        \\
        \\Example TodoList flow:
        \\   ✓ "Set up component structure with placeholder for logic"
        \\   ✓ "Request human collaboration on decision logic implementation"
        \\   ✓ "Integrate contribution and complete feature"
        \\
        \\### Request Format
        \\```
        \\● **Learn by Doing**
        \\**Context:** [what's built and why this decision matters]
        \\**Your Task:** [specific function/section in file, mention file and TODO(human) but do not include line numbers]
        \\**Guidance:** [trade-offs and constraints to consider]
        \\```
        \\
        \\### Key Guidelines
        \\- Frame contributions as valuable design decisions, not busy work
        \\- You must first add a TODO(human) section into the codebase with your editing tools before making the Learn by Doing request
        \\- Make sure there is one and only one TODO(human) section in the code
        \\- Don't take any action or output anything after the Learn by Doing request. Wait for human implementation before proceeding.
        \\
        \\### After Contributions
        \\Share one insight connecting their code to broader patterns or system effects. Avoid praise or repetition.
        ++ EXPLANATORY_FEATURE_PROMPT,
    },
    .{
        .name = "investigative",
        .description = "Lead with evidence, distinguish confirmed findings from inference, and stay source-grounded.",
        .prompt =
        \\Output style: investigative.
        \\Lead with findings and concrete evidence.
        \\Distinguish confirmed observations from inference.
        \\Reference specific files, commands, or tool outputs when making claims.
        \\Avoid speculation that is not grounded in the current tool evidence.
        ,
    },
};

pub fn freeList(allocator: std.mem.Allocator, styles: []OutputStyle) void {
    for (styles) |*style| style.deinit(allocator);
    allocator.free(styles);
}

pub fn clone(allocator: std.mem.Allocator, style: *const OutputStyle) !OutputStyle {
    const name = try allocator.dupe(u8, style.name);
    errdefer allocator.free(name);
    const description = try allocator.dupe(u8, style.description);
    errdefer allocator.free(description);
    const prompt = try allocator.dupe(u8, style.prompt);
    errdefer allocator.free(prompt);
    const source_path = try allocator.dupe(u8, style.source_path);
    return .{
        .name = name,
        .description = description,
        .prompt = prompt,
        .scope = style.scope,
        .source_path = source_path,
        .keep_coding_instructions = style.keep_coding_instructions,
        .force_for_plugin = style.force_for_plugin,
    };
}

pub fn resolve(allocator: std.mem.Allocator, cwd: []const u8, raw_name: []const u8) !OutputStyle {
    // styles-onboarding-02: a plugin style with `force-for-plugin: true`
    // auto-overrides the user's configured style. Consult it first; only fall
    // back to honoring `raw_name` when no plugin forces a style.
    if (try forcedPluginStyle(allocator, cwd)) |forced| {
        return forced;
    }
    if (try findByName(allocator, cwd, raw_name)) |style| {
        return style;
    }
    return cloneBuiltin(allocator, builtin_styles[0], "<builtin:default>");
}

/// styles-onboarding-02: return the plugin-provided output style that declares
/// `force-for-plugin: true`, if any. When more than one plugin style forces, the
/// styles are already sorted by name in `list()`, so the first (alphabetically
/// lowest) wins deterministically; the rest are logged via std.log.warn so the
/// conflict is discoverable. Returns null when no plugin style forces.
pub fn forcedPluginStyle(allocator: std.mem.Allocator, cwd: []const u8) !?OutputStyle {
    const styles = try list(allocator, cwd);
    defer freeList(allocator, styles);

    var chosen: ?*const OutputStyle = null;
    for (styles) |*style| {
        if (style.scope != .plugin or !style.force_for_plugin) continue;
        if (chosen == null) {
            chosen = style;
        } else {
            std.log.warn(
                "output styles: multiple plugin styles force-for-plugin; using '{s}', ignoring '{s}'",
                .{ chosen.?.name, style.name },
            );
        }
    }

    if (chosen) |c| return try clone(allocator, c);
    return null;
}

/// styles-onboarding-01: resolve whether the system prompt should KEEP the base
/// "Doing tasks" coding section for the active style. The default style and the
/// built-in Explanatory/Learning/Investigative styles keep it (they layer on
/// top of coding-agent behavior); a custom style keeps it only if its
/// frontmatter sets `keep-coding-instructions: true`. An unknown name resolves
/// to the default style, which keeps the base section.
pub fn keepCodingInstructions(allocator: std.mem.Allocator, cwd: []const u8, raw_name: []const u8) !bool {
    var style = try resolve(allocator, cwd, raw_name);
    defer style.deinit(allocator);
    return style.keep_coding_instructions;
}

pub fn findByName(allocator: std.mem.Allocator, cwd: []const u8, raw_name: []const u8) !?OutputStyle {
    const requested = std.mem.trim(u8, raw_name, " \t\r\n");
    if (requested.len == 0) return try cloneBuiltin(allocator, builtin_styles[0], "<builtin:default>");

    const styles = try list(allocator, cwd);
    defer freeList(allocator, styles);

    for (styles) |style| {
        if (std.ascii.eqlIgnoreCase(style.name, requested)) {
            return try clone(allocator, &style);
        }
    }
    return null;
}

pub fn list(allocator: std.mem.Allocator, cwd: []const u8) ![]OutputStyle {
    var out = std.array_list.Managed(OutputStyle).init(allocator);
    errdefer freeList(allocator, out.items);

    try appendBuiltinStyles(allocator, &out);

    // styles-onboarding-02: plugin styles sit between builtin and user so a
    // user/workspace style with the same name overrides the plugin one via the
    // last-writer-wins upsert below.
    try appendPluginStyles(allocator, &out, cwd);

    var resolved_paths = try paths.resolve(allocator);
    defer resolved_paths.deinit(allocator);
    const user_root = try std.fs.path.join(allocator, &.{ resolved_paths.zcode_home, "output-styles" });
    defer allocator.free(user_root);
    try appendFromDir(allocator, &out, user_root, .user);

    const workspace_root = try paths.workspacePathAlloc(allocator, cwd, "output-styles");
    defer allocator.free(workspace_root);
    try appendFromDir(allocator, &out, workspace_root, .workspace);

    std.mem.sort(OutputStyle, out.items, {}, lessThan);
    return out.toOwnedSlice();
}

pub fn renderList(allocator: std.mem.Allocator, cwd: []const u8, current: []const u8) ![]u8 {
    const styles = try list(allocator, cwd);
    defer freeList(allocator, styles);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    try out.writer().print("current_output_style={s}\n", .{if (current.len > 0) current else "default"});
    try out.writer().writeAll("output_styles:\n");
    for (styles) |style| {
        const marker = if (std.ascii.eqlIgnoreCase(style.name, current)) "*" else "-";
        try out.writer().print(
            "{s} {s} ({s}) [{s}]\n",
            .{ marker, style.name, scopeName(style.scope), style.description },
        );
    }
    return out.toOwnedSlice();
}

pub fn renderDetail(allocator: std.mem.Allocator, cwd: []const u8, raw_name: []const u8) ![]u8 {
    var style = (try findByName(allocator, cwd, raw_name)) orelse return allocator.dupe(u8, "output style not found");
    defer style.deinit(allocator);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    try out.writer().print("name={s}\n", .{style.name});
    try out.writer().print("scope={s}\n", .{scopeName(style.scope)});
    try out.writer().print("source={s}\n", .{style.source_path});
    try out.writer().print("description={s}\n", .{style.description});
    try out.writer().writeAll("\nprompt:\n");
    try out.writer().writeAll(if (style.prompt.len > 0) style.prompt else "<none>\n");
    if (style.prompt.len > 0 and !std.mem.endsWith(u8, style.prompt, "\n")) {
        try out.writer().writeByte('\n');
    }
    return out.toOwnedSlice();
}

fn appendBuiltinStyles(allocator: std.mem.Allocator, out: *std.array_list.Managed(OutputStyle)) !void {
    for (builtin_styles) |style| {
        const source = try std.fmt.allocPrint(allocator, "<builtin:{s}>", .{style.name});
        defer allocator.free(source);
        var cloned = try cloneBuiltin(allocator, style, source);
        // If append OOMs, free the cloned style's interior strings so they
        // don't leak (previously a silent leak on table growth failure).
        out.append(cloned) catch |err| {
            cloned.deinit(allocator);
            return err;
        };
    }
}

/// styles-onboarding-02: discover plugin-provided output styles. For each
/// enabled plugin (via plugins.list, which applies the trust gate for workspace
/// plugins), look for an `output-styles/` dir under the plugin's root and load
/// its `*.md` files at `.plugin` scope. A missing dir is fine (most plugins
/// ship none). Failures discovering plugins must not break style listing, so a
/// plugins.list error degrades to "no plugin styles".
fn appendPluginStyles(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(OutputStyle),
    cwd: []const u8,
) !void {
    const plugins = plugins_mod.list(allocator, cwd) catch return;
    defer plugins_mod.freeList(allocator, plugins);

    for (plugins) |plugin| {
        if (!plugin.enabled) continue;
        const styles_root = try std.fs.path.join(allocator, &.{ plugin.root_path, "output-styles" });
        defer allocator.free(styles_root);
        try appendFromDir(allocator, out, styles_root, .plugin);
    }
}

fn appendFromDir(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(OutputStyle),
    root: []const u8,
    scope: StyleScope,
) !void {
    var dir = std.Io.Dir.cwd().openDir(rt.io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return,
        error.AccessDenied => return,
        else => return err,
    };
    defer dir.close(rt.io);

    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ root, entry.name });
        defer allocator.free(full_path);
        const style = try loadFile(allocator, full_path, entry.name, scope);
        try upsert(out, allocator, style);
    }
}

fn upsert(out: *std.array_list.Managed(OutputStyle), allocator: std.mem.Allocator, incoming: OutputStyle) !void {
    for (out.items, 0..) |*existing, idx| {
        if (std.ascii.eqlIgnoreCase(existing.name, incoming.name)) {
            existing.deinit(allocator);
            out.items[idx] = incoming;
            return;
        }
    }
    // Free incoming on append OOM so the caller does not leak its strings.
    out.append(incoming) catch |err| {
        var tmp = incoming;
        tmp.deinit(allocator);
        return err;
    };
}

fn loadFile(allocator: std.mem.Allocator, path: []const u8, filename: []const u8, scope: StyleScope) !OutputStyle {
    const raw = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(raw);

    const basename = if (filename.len > 3 and std.mem.endsWith(u8, filename, ".md")) filename[0 .. filename.len - 3] else filename;
    const parsed = parseStyleSource(raw);

    return .{
        .name = try allocator.dupe(u8, if (parsed.name.len > 0) parsed.name else basename),
        .description = try allocator.dupe(u8, if (parsed.description.len > 0) parsed.description else "Custom output style"),
        .prompt = try allocator.dupe(u8, parsed.prompt),
        .scope = scope,
        .source_path = try allocator.dupe(u8, path),
        .keep_coding_instructions = parsed.keep_coding_instructions,
        // force-for-plugin only applies to plugin-scoped styles; a user or
        // workspace style setting the flag has no effect.
        .force_for_plugin = scope == .plugin and parsed.force_for_plugin,
    };
}

const ParsedStyleSource = struct {
    name: []const u8,
    description: []const u8,
    prompt: []const u8,
    /// styles-onboarding-01: parsed from `keep-coding-instructions` frontmatter.
    /// Defaults to false for custom styles (a custom style fully replaces the
    /// base coding behavior unless it opts back in).
    keep_coding_instructions: bool,
    /// styles-onboarding-02: parsed from `force-for-plugin` frontmatter.
    /// Defaults to false; only honored for plugin-scoped styles.
    force_for_plugin: bool,
};

fn parseStyleSource(raw: []const u8) ParsedStyleSource {
    var name: []const u8 = "";
    var description: []const u8 = "";
    var keep_coding: bool = false;
    var force_for_plugin: bool = false;
    var prompt = std.mem.trim(u8, raw, " \t\r\n");

    if (frontmatter_mod.extract(raw)) |block| {
        prompt = std.mem.trim(u8, block.rest, " \t\r\n");
        if (frontmatter_mod.getValue(block.body, "name")) |v| name = v;
        if (frontmatter_mod.getValue(block.body, "description")) |v| description = v;
        keep_coding = parseBool(frontmatter_mod.getValue(block.body, "keep-coding-instructions"), false);
        force_for_plugin = parseBool(frontmatter_mod.getValue(block.body, "force-for-plugin"), false);
    }

    return .{
        .name = name,
        .description = description,
        .prompt = prompt,
        .keep_coding_instructions = keep_coding,
        .force_for_plugin = force_for_plugin,
    };
}

/// Parse a frontmatter bool value. Accepts true/false, yes/no, 1/0
/// (case-insensitive). Mirrors skill_types.parseBool semantics; kept local
/// because that helper is file-private to skill_types.zig.
fn parseBool(v: ?[]const u8, default: bool) bool {
    const s = std.mem.trim(u8, v orelse return default, " \t\r\n");
    if (s.len == 0) return default;
    if (std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1") or std.ascii.eqlIgnoreCase(s, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(s, "false") or std.mem.eql(u8, s, "0") or std.ascii.eqlIgnoreCase(s, "no")) return false;
    return default;
}

const frontmatter_mod = @import("frontmatter.zig");

fn cloneBuiltin(allocator: std.mem.Allocator, builtin: BuiltinStyle, source_path: []const u8) !OutputStyle {
    const name = try allocator.dupe(u8, builtin.name);
    errdefer allocator.free(name);
    const description = try allocator.dupe(u8, builtin.description);
    errdefer allocator.free(description);
    const prompt = try allocator.dupe(u8, builtin.prompt);
    errdefer allocator.free(prompt);
    const dup_source = try allocator.dupe(u8, source_path);
    return .{
        .name = name,
        .description = description,
        .prompt = prompt,
        .scope = .builtin,
        .source_path = dup_source,
        .keep_coding_instructions = builtin.keep_coding_instructions,
        // Builtin styles are never plugin-forced.
        .force_for_plugin = false,
    };
}

fn lessThan(_: void, a: OutputStyle, b: OutputStyle) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn scopeName(scope: StyleScope) []const u8 {
    return switch (scope) {
        .builtin => "builtin",
        .plugin => "plugin",
        .user => "user",
        .workspace => "workspace",
    };
}

const testing = std.testing;

test "list includes builtin output styles" {
    const styles = try list(testing.allocator, ".");
    defer freeList(testing.allocator, styles);

    var found_default = false;
    var found_investigative = false;
    for (styles) |style| {
        if (std.mem.eql(u8, style.name, "default")) found_default = true;
        if (std.mem.eql(u8, style.name, "investigative")) found_investigative = true;
    }
    try testing.expect(found_default);
    try testing.expect(found_investigative);
}

test "workspace output style overrides builtin" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, "repo/.zcode/output-styles");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "repo/.zcode/output-styles/investigative.md",
        .data = "---\n" ++
            "description: Workspace investigative override\n" ++
            "---\n\n" ++
            "Use a repo-specific evidence-first voice.\n",
    });

    const cwd = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "repo");
    defer testing.allocator.free(cwd);

    var style = (try findByName(testing.allocator, cwd, "investigative")).?;
    defer style.deinit(testing.allocator);

    try testing.expectEqual(style.scope, .workspace);
    try testing.expectEqualStrings("Workspace investigative override", style.description);
    try testing.expect(std.mem.indexOf(u8, style.prompt, "repo-specific evidence-first voice") != null);
}

test "parse style frontmatter extracts metadata" {
    const parsed = parseStyleSource(
        "---\n" ++
            "name: review-plus\n" ++
            "description: Focus on findings first\n" ++
            "---\n\n" ++
            "Lead with findings.\n",
    );

    try testing.expectEqualStrings("review-plus", parsed.name);
    try testing.expectEqualStrings("Focus on findings first", parsed.description);
    try testing.expectEqualStrings("Lead with findings.", parsed.prompt);
}

test "explanatory builtin style ships the Insight format" {
    var style = (try findByName(testing.allocator, ".", "explanatory")).?;
    defer style.deinit(testing.allocator);

    // The Insight block header must survive -- without it the model
    // emits the educational asides without the visual boundary and
    // they blend into normal output.
    try testing.expect(std.mem.indexOf(u8, style.prompt, "# Explanatory Style Active") != null);
    try testing.expect(std.mem.indexOf(u8, style.prompt, "## Insights") != null);
    try testing.expect(std.mem.indexOf(u8, style.prompt, "\xe2\x9c\xb6 Insight") != null); // ✶
    try testing.expect(std.mem.indexOf(u8, style.prompt, "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80") != null); // ──── rule
}

test "parse style frontmatter defaults keep-coding-instructions to false" {
    const parsed = parseStyleSource(
        "---\n" ++
            "description: Replacer\n" ++
            "---\n\n" ++
            "Replace the coding agent.\n",
    );
    try testing.expect(!parsed.keep_coding_instructions);
}

test "parse style frontmatter reads keep-coding-instructions true" {
    const parsed = parseStyleSource(
        "---\n" ++
            "description: Layered\n" ++
            "keep-coding-instructions: true\n" ++
            "---\n\n" ++
            "Layer on top.\n",
    );
    try testing.expect(parsed.keep_coding_instructions);
}

test "builtin default and learning styles keep coding instructions" {
    var def = (try findByName(testing.allocator, ".", "default")).?;
    defer def.deinit(testing.allocator);
    try testing.expect(def.keep_coding_instructions);

    var learning = (try findByName(testing.allocator, ".", "learning")).?;
    defer learning.deinit(testing.allocator);
    try testing.expect(learning.keep_coding_instructions);

    var explanatory = (try findByName(testing.allocator, ".", "explanatory")).?;
    defer explanatory.deinit(testing.allocator);
    try testing.expect(explanatory.keep_coding_instructions);
}

test "keepCodingInstructions: custom style without flag drops the base section" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, "repo/.zcode/output-styles");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "repo/.zcode/output-styles/replacer.md",
        .data = "---\n" ++
            "description: Fully replaces coding behavior\n" ++
            "---\n\n" ++
            "You are now a different kind of assistant.\n",
    });

    const cwd = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "repo");
    defer testing.allocator.free(cwd);

    // A custom style with no keep-coding-instructions frontmatter -> false.
    try testing.expect(!(try keepCodingInstructions(testing.allocator, cwd, "replacer")));
    // The built-in default still keeps the base section.
    try testing.expect(try keepCodingInstructions(testing.allocator, cwd, "default"));
    // An unknown style resolves to default -> keeps the base section.
    try testing.expect(try keepCodingInstructions(testing.allocator, cwd, "zzzznope"));
}

test "keepCodingInstructions: custom style opting in keeps the base section" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, "repo/.zcode/output-styles");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "repo/.zcode/output-styles/layered.md",
        .data = "---\n" ++
            "description: Layers on top of coding behavior\n" ++
            "keep-coding-instructions: true\n" ++
            "---\n\n" ++
            "Add an educational voice on top of normal coding.\n",
    });

    const cwd = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "repo");
    defer testing.allocator.free(cwd);

    try testing.expect(try keepCodingInstructions(testing.allocator, cwd, "layered"));
}

test "learning builtin style ships the Learn by Doing request format" {
    var style = (try findByName(testing.allocator, ".", "learning")).?;
    defer style.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, style.prompt, "# Learning Style Active") != null);
    try testing.expect(std.mem.indexOf(u8, style.prompt, "Learn by Doing") != null);
    try testing.expect(std.mem.indexOf(u8, style.prompt, "TODO(human)") != null);
    try testing.expect(std.mem.indexOf(u8, style.prompt, "**Context:**") != null);
    try testing.expect(std.mem.indexOf(u8, style.prompt, "**Your Task:**") != null);
    try testing.expect(std.mem.indexOf(u8, style.prompt, "**Guidance:**") != null);
    // The Learning style also ships the shared Insight tail.
    try testing.expect(std.mem.indexOf(u8, style.prompt, "## Insights") != null);
}

// ── styles-onboarding-02: plugin output styles + force-for-plugin ──────────

test "parse style frontmatter reads force-for-plugin true" {
    const parsed = parseStyleSource(
        "---\n" ++
            "description: Plugin replacer\n" ++
            "force-for-plugin: true\n" ++
            "---\n\n" ++
            "Plugin voice.\n",
    );
    try testing.expect(parsed.force_for_plugin);
}

test "parse style frontmatter defaults force-for-plugin to false" {
    const parsed = parseStyleSource(
        "---\n" ++
            "description: Plain\n" ++
            "---\n\n" ++
            "Body.\n",
    );
    try testing.expect(!parsed.force_for_plugin);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Pin HOME (and clear XDG_CONFIG_HOME) to `home` so paths.resolve resolves the
/// zcode home into the tmp tree. Returns a struct whose `restore` puts the prior
/// env back. Mirrors the env-pinning dance in plugins.zig's Task 5 test.
const HomeGuard = struct {
    prev_home: ?[]u8,
    prev_xdg: ?[]u8,

    fn restore(self: *HomeGuard, alloc: std.mem.Allocator) void {
        if (self.prev_home) |h| {
            const z = alloc.dupeZ(u8, h) catch null;
            if (z) |zz| {
                _ = setenv("HOME", zz, 1);
                alloc.free(zz);
            }
            alloc.free(h);
        } else _ = unsetenv("HOME");
        if (self.prev_xdg) |x| {
            const z = alloc.dupeZ(u8, x) catch null;
            if (z) |zz| {
                _ = setenv("XDG_CONFIG_HOME", zz, 1);
                alloc.free(zz);
            }
            alloc.free(x);
        } else _ = unsetenv("XDG_CONFIG_HOME");
    }
};

fn pinHome(alloc: std.mem.Allocator, home: []const u8) !HomeGuard {
    const env_mod = @import("env.zig");
    const prev_home = env_mod.getOwned(alloc, "HOME") catch null;
    const prev_xdg = env_mod.getOwned(alloc, "XDG_CONFIG_HOME") catch null;
    const home_z = try alloc.dupeZ(u8, home);
    defer alloc.free(home_z);
    _ = setenv("HOME", home_z, 1);
    _ = unsetenv("XDG_CONFIG_HOME");
    return .{ .prev_home = prev_home, .prev_xdg = prev_xdg };
}

/// Write a user plugin (always loads enabled) carrying an output-style file.
fn writePluginStyle(
    tmp: *std.testing.TmpDir,
    plugin_name: []const u8,
    style_file: []const u8,
    style_data: []const u8,
) !void {
    var buf: [256]u8 = undefined;
    const plugin_dir = try std.fmt.bufPrint(&buf, ".zcode/plugins/{s}", .{plugin_name});
    try tmp.dir.createDirPath(rt.io, plugin_dir);

    var buf2: [256]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(&buf2, ".zcode/plugins/{s}/plugin.json", .{plugin_name});
    var buf3: [256]u8 = undefined;
    const manifest = try std.fmt.bufPrint(&buf3,
        \\{{ "name": "{s}", "version": "1.0.0", "description": "test", "entrypoint": "run.sh" }}
    , .{plugin_name});
    try tmp.dir.writeFile(rt.io, .{ .sub_path = manifest_path, .data = manifest });

    var buf4: [256]u8 = undefined;
    const styles_dir = try std.fmt.bufPrint(&buf4, ".zcode/plugins/{s}/output-styles", .{plugin_name});
    try tmp.dir.createDirPath(rt.io, styles_dir);

    var buf5: [256]u8 = undefined;
    const style_path = try std.fmt.bufPrint(&buf5, ".zcode/plugins/{s}/output-styles/{s}", .{ plugin_name, style_file });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = style_path, .data = style_data });
}

test "styles-onboarding-02: plugin output style appears in list with plugin scope" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(home);
    var guard = try pinHome(alloc, home);
    defer guard.restore(alloc);

    try writePluginStyle(&tmp, "styler", "foo.md", "---\n" ++
        "description: Plugin foo style\n" ++
        "---\n\n" ++
        "Use the plugin voice.\n");

    // cwd is a distinct subdir with no workspace plugins/styles.
    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    const styles = try list(alloc, cwd);
    defer freeList(alloc, styles);

    var found: ?*const OutputStyle = null;
    for (styles) |*s| {
        if (std.mem.eql(u8, s.name, "foo")) found = s;
    }
    try testing.expect(found != null);
    try testing.expectEqual(StyleScope.plugin, found.?.scope);
    try testing.expectEqualStrings("Plugin foo style", found.?.description);
}

test "styles-onboarding-02: user style overrides a plugin style with the same name" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(home);
    var guard = try pinHome(alloc, home);
    defer guard.restore(alloc);

    // Plugin ships a style named "shared".
    try writePluginStyle(&tmp, "styler", "shared.md", "---\n" ++
        "description: From the plugin\n" ++
        "---\n\n" ++
        "Plugin body.\n");

    // User ships a style with the SAME name under the user output-styles root.
    try tmp.dir.createDirPath(rt.io, ".zcode/output-styles");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/output-styles/shared.md",
        .data = "---\n" ++
            "description: From the user\n" ++
            "---\n\n" ++
            "User body.\n",
    });

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    var style = (try findByName(alloc, cwd, "shared")).?;
    defer style.deinit(alloc);

    // User priority beats plugin priority via last-writer-wins upsert.
    try testing.expectEqual(StyleScope.user, style.scope);
    try testing.expectEqualStrings("From the user", style.description);
}

test "styles-onboarding-02: force-for-plugin auto-overrides the configured style" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(home);
    var guard = try pinHome(alloc, home);
    defer guard.restore(alloc);

    try writePluginStyle(&tmp, "styler", "forced.md", "---\n" ++
        "description: Forced plugin style\n" ++
        "force-for-plugin: true\n" ++
        "---\n\n" ++
        "Forced plugin voice.\n");

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // forcedPluginStyle returns the forced style.
    var forced = (try forcedPluginStyle(alloc, cwd)).?;
    defer forced.deinit(alloc);
    try testing.expectEqualStrings("forced", forced.name);
    try testing.expectEqual(StyleScope.plugin, forced.scope);

    // resolve("default") returns the forced plugin style, not the builtin
    // default, because force-for-plugin auto-overrides the configured style.
    var resolved = try resolve(alloc, cwd, "default");
    defer resolved.deinit(alloc);
    try testing.expectEqualStrings("forced", resolved.name);
    try testing.expectEqual(StyleScope.plugin, resolved.scope);
}

test "styles-onboarding-02: two forced plugin styles pick the alphabetically first deterministically" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(home);
    var guard = try pinHome(alloc, home);
    defer guard.restore(alloc);

    // Two distinct plugins each force a style: "aaa" and "zzz".
    try writePluginStyle(&tmp, "plug_z", "zzz.md", "---\n" ++
        "description: Z forces\n" ++
        "force-for-plugin: true\n" ++
        "---\n\n" ++
        "Z body.\n");
    try writePluginStyle(&tmp, "plug_a", "aaa.md", "---\n" ++
        "description: A forces\n" ++
        "force-for-plugin: true\n" ++
        "---\n\n" ++
        "A body.\n");

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // list() sorts by name, so the first forced style encountered is "aaa".
    var forced = (try forcedPluginStyle(alloc, cwd)).?;
    defer forced.deinit(alloc);
    try testing.expectEqualStrings("aaa", forced.name);
}

test "styles-onboarding-02: no plugin styles -> resolve honors the configured name" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(home);
    var guard = try pinHome(alloc, home);
    defer guard.restore(alloc);

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // No forced plugin style -> null.
    try testing.expect((try forcedPluginStyle(alloc, cwd)) == null);

    // resolve still honors the requested builtin name.
    var resolved = try resolve(alloc, cwd, "explanatory");
    defer resolved.deinit(alloc);
    try testing.expectEqualStrings("explanatory", resolved.name);
}
