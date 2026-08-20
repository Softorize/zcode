const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const paths = @import("paths.zig");
const arg_sub = @import("argument_substitution.zig");
const display_safe = @import("display_safe.zig");
const skill_types = @import("skill_types.zig");
const frontmatter = @import("frontmatter.zig");
const command_namespace = @import("command_namespace.zig");

pub const CommandScope = enum {
    user,
    workspace,
};

/// Mirror of SkillContext so custom commands can carry the same execution-mode
/// field as skills (inline vs fork). Aliased here so callers do not have to
/// reach into skill_types for a command field.
pub const CommandContext = skill_types.SkillContext;

pub const CommandSpec = struct {
    name: []u8,
    scope: CommandScope,
    path: []u8,
    description: []u8,
    /// Frontmatter-stripped body (the template the model receives). When the
    /// file has no frontmatter this is the whole file.
    prompt: []u8,
    /// `argument-hint` frontmatter; empty when absent. Gray typeahead hint.
    argument_hint: []u8,
    /// Tools auto-allowed while the command runs (`allowed-tools`).
    allowed_tools: [][]u8,
    /// Named argument slots for `$foo` substitution (`arguments` frontmatter).
    arg_names: [][]u8,
    /// Per-command model override; empty = inherit from session.
    model: []u8,
    /// `when-to-use` frontmatter; empty when absent.
    when_to_use: []u8,
    /// Per-command agent override; empty = inherit.
    agent: []u8,
    /// Glob patterns gating visibility (`paths` frontmatter).
    paths: [][]u8,
    user_invocable: bool,
    disable_model_invocation: bool,
    version: []u8,
    context: CommandContext,

    pub fn deinit(self: *CommandSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.description);
        allocator.free(self.prompt);
        allocator.free(self.argument_hint);
        allocator.free(self.model);
        allocator.free(self.when_to_use);
        allocator.free(self.agent);
        allocator.free(self.version);
        skill_types.freeStrList(allocator, self.allowed_tools);
        skill_types.freeStrList(allocator, self.arg_names);
        skill_types.freeStrList(allocator, self.paths);
    }
};

fn dupeStrList(allocator: std.mem.Allocator, items: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, items.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |s| allocator.free(s);
        allocator.free(out);
    }
    for (items, 0..) |s, i| {
        out[i] = try allocator.dupe(u8, s);
        filled = i + 1;
    }
    return out;
}

/// Deep-copy a CommandSpec. Mirrors skill_types.clone so a partial-free bug on
/// error is impossible (every owned field is allocated through the errdefer
/// chain in dupeStrList / the field-by-field dupes below).
fn cloneSpec(allocator: std.mem.Allocator, command: *const CommandSpec) !CommandSpec {
    const name = try allocator.dupe(u8, command.name);
    errdefer allocator.free(name);
    const path = try allocator.dupe(u8, command.path);
    errdefer allocator.free(path);
    const description = try allocator.dupe(u8, command.description);
    errdefer allocator.free(description);
    const prompt = try allocator.dupe(u8, command.prompt);
    errdefer allocator.free(prompt);
    const argument_hint = try allocator.dupe(u8, command.argument_hint);
    errdefer allocator.free(argument_hint);
    const model = try allocator.dupe(u8, command.model);
    errdefer allocator.free(model);
    const when_to_use = try allocator.dupe(u8, command.when_to_use);
    errdefer allocator.free(when_to_use);
    const agent = try allocator.dupe(u8, command.agent);
    errdefer allocator.free(agent);
    const version = try allocator.dupe(u8, command.version);
    errdefer allocator.free(version);
    const allowed_tools = try dupeStrList(allocator, command.allowed_tools);
    errdefer skill_types.freeStrList(allocator, allowed_tools);
    const arg_names = try dupeStrList(allocator, command.arg_names);
    errdefer skill_types.freeStrList(allocator, arg_names);
    const paths_list = try dupeStrList(allocator, command.paths);
    return .{
        .name = name,
        .scope = command.scope,
        .path = path,
        .description = description,
        .prompt = prompt,
        .argument_hint = argument_hint,
        .allowed_tools = allowed_tools,
        .arg_names = arg_names,
        .model = model,
        .when_to_use = when_to_use,
        .agent = agent,
        .paths = paths_list,
        .user_invocable = command.user_invocable,
        .disable_model_invocation = command.disable_model_invocation,
        .version = version,
        .context = command.context,
    };
}

pub fn scopeName(scope: CommandScope) []const u8 {
    return switch (scope) {
        .user => "user",
        .workspace => "workspace",
    };
}

pub fn list(allocator: std.mem.Allocator, cwd: []const u8) ![]CommandSpec {
    var out = std.array_list.Managed(CommandSpec).init(allocator);
    errdefer freeList(allocator, out.items);

    if (userCommandsRoot(allocator)) |root| {
        defer allocator.free(root);
        try appendCommandsFromRoot(allocator, &out, root, .user);
    } else |_| {}

    const workspace_root = try paths.workspacePathAlloc(allocator, cwd, "commands");
    defer allocator.free(workspace_root);
    try appendCommandsFromRoot(allocator, &out, workspace_root, .workspace);

    return out.toOwnedSlice();
}

pub fn renderList(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const commands = try list(allocator, cwd);
    defer freeList(allocator, commands);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    if (commands.len == 0) {
        try out.writer().writeAll("commands: none\n");
        return out.toOwnedSlice();
    }

    try out.writer().writeAll("commands:\n");
    for (commands) |command| {
        const safe_name = try display_safe.sanitize(allocator, command.name);
        defer allocator.free(safe_name);
        const safe_desc = try display_safe.sanitize(allocator, command.description);
        defer allocator.free(safe_desc);
        try out.writer().print("- {s} ({s}) [{s}] {s}\n", .{
            safe_name,
            scopeName(command.scope),
            command.path,
            safe_desc,
        });
    }
    return out.toOwnedSlice();
}

pub fn renderDetail(allocator: std.mem.Allocator, cwd: []const u8, name: []const u8) ![]u8 {
    var command = try findByName(allocator, cwd, name);
    defer command.deinit(allocator);

    // Body intentionally NOT sanitized -- the user asked to see the literal
    // command body. Header fields must stay on a single line each. The body is
    // the frontmatter-stripped prompt; the parsed metadata is surfaced as the
    // header lines below so the user does not have to eyeball the raw YAML.
    const safe_name = try display_safe.sanitize(allocator, command.name);
    defer allocator.free(safe_name);
    const safe_desc = try display_safe.sanitize(allocator, command.description);
    defer allocator.free(safe_desc);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    try out.writer().print("name: {s}\n", .{safe_name});
    try out.writer().print("scope: {s}\n", .{scopeName(command.scope)});
    try out.writer().print("path: {s}\n", .{command.path});
    try out.writer().print("description: {s}\n", .{safe_desc});
    if (command.argument_hint.len > 0) {
        const safe_hint = try display_safe.sanitize(allocator, command.argument_hint);
        defer allocator.free(safe_hint);
        try out.writer().print("argument-hint: {s}\n", .{safe_hint});
    }
    if (command.allowed_tools.len > 0) {
        try out.writer().writeAll("allowed-tools:");
        for (command.allowed_tools, 0..) |tool, i| {
            const safe_tool = try display_safe.sanitize(allocator, tool);
            defer allocator.free(safe_tool);
            try out.writer().print("{s} {s}", .{ if (i == 0) "" else ",", safe_tool });
        }
        try out.writer().writeByte('\n');
    }
    if (command.model.len > 0) {
        const safe_model = try display_safe.sanitize(allocator, command.model);
        defer allocator.free(safe_model);
        try out.writer().print("model: {s}\n", .{safe_model});
    }
    try out.writer().print("user-invocable: {s}\n", .{if (command.user_invocable) "true" else "false"});

    try out.writer().writeByte('\n');
    try out.writer().writeAll(command.prompt);
    return out.toOwnedSlice();
}

pub fn renderRun(allocator: std.mem.Allocator, cwd: []const u8, name: []const u8, args: []const u8) ![]u8 {
    var command = try findByName(allocator, cwd, name);
    defer command.deinit(allocator);

    // Substitute on the frontmatter-stripped prompt so YAML never leaks into the
    // model prompt. Run BOTH placeholder syntaxes so user templates from either
    // ecosystem keep working:
    //   1. Reference Claude Code style: $ARGUMENTS, $ARGUMENTS[N], $0, $1, and
    //      named $foo from the `arguments` frontmatter (now threaded via
    //      command.arg_names, matching how skills' renderRun works).
    //   2. zcode legacy: {{args}}, {{arg1}}
    // We pass append=false to the reference pass so we don't double-tag with
    // "ARGUMENTS:" -- the legacy pass below handles the no-placeholder case.
    const body = command.prompt;
    const stage1 = try arg_sub.substituteArguments(allocator, body, args, false, command.arg_names);
    defer allocator.free(stage1);

    const stage2 = try substituteArgs(allocator, stage1, args);

    // Append ARGUMENTS: <args> only when neither pass touched the
    // template AND the user actually supplied args.
    if (args.len > 0 and std.mem.eql(u8, stage2, body)) {
        defer allocator.free(stage2);
        return std.fmt.allocPrint(allocator, "{s}\n\nARGUMENTS: {s}", .{ body, args });
    }
    return stage2;
}

pub fn freeList(allocator: std.mem.Allocator, commands: []CommandSpec) void {
    for (commands) |*command| command.deinit(allocator);
    allocator.free(commands);
}

fn appendCommandsFromRoot(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(CommandSpec),
    root: []const u8,
    scope: CommandScope,
) !void {
    // Start the namespaced walk at the root with an empty prefix. Files directly
    // under `root` get bare names; files in subdirectories get `dir:...:stem`.
    try appendCommandsFromDir(allocator, out, root, "", scope, 0);
}

/// Recursive walk of a commands directory. `prefix` is the `:`-joined chain of
/// parent directory names below the original root (empty at the root). `depth`
/// guards against pathological symlink loops.
fn appendCommandsFromDir(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(CommandSpec),
    dir_path: []const u8,
    prefix: []const u8,
    scope: CommandScope,
    depth: usize,
) !void {
    if (depth > command_namespace.max_depth) return;

    var dir = std.Io.Dir.cwd().openDir(rt.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(rt.io);

    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        if (entry.kind == .directory) {
            // Recurse: extend the namespace prefix with this directory's name and
            // walk it. Symlinked dirs are reported as .sym_link (not .directory)
            // so this naturally skips them.
            const child_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(child_path);
            const child_prefix = try command_namespace.extend(allocator, prefix, entry.name);
            defer allocator.free(child_prefix);
            try appendCommandsFromDir(allocator, out, child_path, child_prefix, scope, depth + 1);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!(std.mem.endsWith(u8, entry.name, ".md") or std.mem.endsWith(u8, entry.name, ".txt"))) continue;

        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        // Namespaced command name: `<prefix>:<stem>` (or just `<stem>` at root).
        const ns_name = command_namespace.join(allocator, prefix, command_namespace.fileStem(entry.name)) catch |err| {
            allocator.free(path);
            return err;
        };
        defer allocator.free(ns_name);
        // Once parseCommandFile succeeds it owns `path`; until then this guard
        // frees it. parseCommandFile never returns a spec on the error path, so
        // there is no double-free: either it errors (path still ours, freed
        // here) or it succeeds (path moved into the spec, guard discharged).
        var spec = parseCommandFile(allocator, path, ns_name, scope) catch |err| {
            allocator.free(path);
            // Oversize / unreadable files are skipped rather than aborting the
            // whole listing. readFileAlloc(.limited) yields StreamTooLong, not
            // FileTooBig, on the 0.16 toolchain.
            if (err == error.StreamTooLong) continue;
            return err;
        };
        errdefer spec.deinit(allocator);
        try out.append(spec);
    }
}

/// Parse a single command file into a CommandSpec. Delegates the frontmatter
/// parsing to skill_types.parse (the shared, complete parser) so the same set
/// of fields skills already support are bound here; argument-hint is parsed
/// separately because skill_types does not yet store it (Task 5 owns that).
/// Takes ownership of `path` (frees it on success path inside the returned
/// spec; the caller's errdefer covers the failure path before this is called).
fn parseCommandFile(
    allocator: std.mem.Allocator,
    path: []u8,
    name: []const u8,
    scope: CommandScope,
) !CommandSpec {
    const raw = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(96 * 1024));
    defer allocator.free(raw);

    // skill_types.parse wants a SkillScope; the parsed scope value is discarded
    // here (we keep the CommandScope), so a sentinel is fine.
    var parsed = try skill_types.parse(allocator, raw, name, .user, path);
    defer parsed.deinit(allocator);

    // argument-hint is not a stored field on SkillSpec yet, so read it directly
    // from the frontmatter block.
    const arg_hint: []const u8 = blk: {
        if (frontmatter.extract(raw)) |block| {
            if (frontmatter.getValue(block.body, "argument-hint")) |v| break :blk v;
            if (frontmatter.getValue(block.body, "argumentHint")) |v| break :blk v;
        }
        break :blk "";
    };

    // Build the spec; transfer ownership of `path` into the spec.name/path.
    const sp_name = try allocator.dupe(u8, parsed.name);
    errdefer allocator.free(sp_name);
    const sp_description = try allocator.dupe(u8, parsed.description);
    errdefer allocator.free(sp_description);
    const sp_prompt = try allocator.dupe(u8, parsed.prompt);
    errdefer allocator.free(sp_prompt);
    const sp_arg_hint = try allocator.dupe(u8, arg_hint);
    errdefer allocator.free(sp_arg_hint);
    const sp_model = try allocator.dupe(u8, parsed.model);
    errdefer allocator.free(sp_model);
    const sp_when = try allocator.dupe(u8, parsed.when_to_use);
    errdefer allocator.free(sp_when);
    const sp_agent = try allocator.dupe(u8, parsed.agent);
    errdefer allocator.free(sp_agent);
    const sp_version = try allocator.dupe(u8, parsed.version);
    errdefer allocator.free(sp_version);
    const sp_allowed = try dupeStrList(allocator, parsed.allowed_tools);
    errdefer skill_types.freeStrList(allocator, sp_allowed);
    const sp_args = try dupeStrList(allocator, parsed.arg_names);
    errdefer skill_types.freeStrList(allocator, sp_args);
    const sp_paths = try dupeStrList(allocator, parsed.paths);

    return .{
        .name = sp_name,
        .scope = scope,
        .path = path,
        .description = sp_description,
        .prompt = sp_prompt,
        .argument_hint = sp_arg_hint,
        .allowed_tools = sp_allowed,
        .arg_names = sp_args,
        .model = sp_model,
        .when_to_use = sp_when,
        .agent = sp_agent,
        .paths = sp_paths,
        .user_invocable = parsed.user_invocable,
        .disable_model_invocation = parsed.disable_model_invocation,
        .version = sp_version,
        .context = parsed.context,
    };
}

fn findByName(allocator: std.mem.Allocator, cwd: []const u8, name: []const u8) !CommandSpec {
    const commands = try list(allocator, cwd);
    defer freeList(allocator, commands);

    for (commands) |*command| {
        if (!std.mem.eql(u8, command.name, name)) continue;
        return cloneSpec(allocator, command);
    }
    return error.CommandNotFound;
}

fn userCommandsRoot(allocator: std.mem.Allocator) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return std.fs.path.join(allocator, &.{ resolved.zcode_home, "commands" });
}

fn substituteArgs(allocator: std.mem.Allocator, template: []const u8, args: []const u8) ![]u8 {
    var rendered = try replaceToken(allocator, template, "{{args}}", args);
    errdefer allocator.free(rendered);

    var tokens = std.mem.tokenizeScalar(u8, args, ' ');
    var index: usize = 1;
    while (tokens.next()) |token| : (index += 1) {
        const placeholder = try std.fmt.allocPrint(allocator, "{{arg{d}}}", .{index});
        defer allocator.free(placeholder);

        const next = try replaceToken(allocator, rendered, placeholder, token);
        allocator.free(rendered);
        rendered = next;
    }
    return rendered;
}

fn replaceToken(allocator: std.mem.Allocator, input: []const u8, token: []const u8, replacement: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, input, cursor, token)) |idx| {
        try out.appendSlice(input[cursor..idx]);
        try out.appendSlice(replacement);
        cursor = idx + token.len;
    }
    try out.appendSlice(input[cursor..]);
    return out.toOwnedSlice();
}

const testing = std.testing;

test "renderRun substitutes command args" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/commands");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/commands/review.md",
        .data =
        \\Review these changes:
        \\- target: {{arg1}}
        \\- context: {{args}}
        ,
    });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(cwd);

    const rendered = try renderRun(allocator, cwd, "review", "src/main.zig fast");
    defer allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "fast") != null);
}

test "renderRun substitutes reference $ARGUMENTS placeholders" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/commands");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/commands/audit.md",
        .data =
        \\Audit task:
        \\- target: $ARGUMENTS[0]
        \\- mode:   $1
        \\- raw:    $ARGUMENTS
        ,
    });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(cwd);

    const rendered = try renderRun(allocator, cwd, "audit", "src/foo.zig fast");
    defer allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "target: src/foo.zig") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "mode:   fast") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "raw:    src/foo.zig fast") != null);
}

test "renderRun appends ARGUMENTS line when template has no placeholder" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/commands");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/commands/static.md",
        .data = "Plain template with no placeholders.",
    });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(cwd);

    const rendered = try renderRun(allocator, cwd, "static", "drop me here");
    defer allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "Plain template with no placeholders.") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "ARGUMENTS: drop me here") != null);
}

test "renderRun does NOT append when args is empty" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/commands");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/commands/static2.md",
        .data = "Plain template with no placeholders.",
    });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(cwd);

    const rendered = try renderRun(allocator, cwd, "static2", "");
    defer allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "ARGUMENTS:") == null);
    try testing.expectEqualStrings("Plain template with no placeholders.", rendered);
}

fn findInList(commands: []CommandSpec, name: []const u8) ?*CommandSpec {
    for (commands) |*c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

test "list parses command frontmatter into CommandSpec fields" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/commands");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/commands/review.md",
        .data =
        \\---
        \\description: Review a pull request
        \\argument-hint: <pr-url>
        \\allowed-tools: GitDiff, Bash
        \\arguments: url mode
        \\model: opus
        \\---
        \\Review $url in $mode
        ,
    });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(cwd);

    const commands = try list(allocator, cwd);
    defer freeList(allocator, commands);

    const spec = findInList(commands, "review") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Review a pull request", spec.description);
    try testing.expectEqualStrings("<pr-url>", spec.argument_hint);
    try testing.expectEqual(@as(usize, 2), spec.allowed_tools.len);
    try testing.expectEqualStrings("GitDiff", spec.allowed_tools[0]);
    try testing.expectEqualStrings("Bash", spec.allowed_tools[1]);
    try testing.expectEqual(@as(usize, 2), spec.arg_names.len);
    try testing.expectEqualStrings("url", spec.arg_names[0]);
    try testing.expectEqualStrings("mode", spec.arg_names[1]);
    try testing.expectEqualStrings("opus", spec.model);
    // Frontmatter must NOT leak into the stored prompt body.
    try testing.expect(std.mem.indexOf(u8, spec.prompt, "argument-hint") == null);
    try testing.expect(std.mem.indexOf(u8, spec.prompt, "Review $url in $mode") != null);
}

test "renderRun binds named arguments from frontmatter" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/commands");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/commands/review.md",
        .data =
        \\---
        \\description: Review a pull request
        \\arguments: url mode
        \\---
        \\Review $url in $mode
        ,
    });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(cwd);

    const rendered = try renderRun(allocator, cwd, "review", "https://x fast");
    defer allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "Review https://x in fast") != null);
    // The named-argument substitution must consume $url / $mode (no leftovers).
    try testing.expect(std.mem.indexOf(u8, rendered, "$url") == null);
    try testing.expect(std.mem.indexOf(u8, rendered, "$mode") == null);
}

test "renderDetail surfaces parsed metadata header" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/commands");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/commands/review.md",
        .data =
        \\---
        \\description: Review a pull request
        \\argument-hint: <pr-url>
        \\allowed-tools: GitDiff, Bash
        \\model: opus
        \\---
        \\Body line.
        ,
    });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(cwd);

    const detail = try renderDetail(allocator, cwd, "review");
    defer allocator.free(detail);

    try testing.expect(std.mem.indexOf(u8, detail, "argument-hint: <pr-url>") != null);
    try testing.expect(std.mem.indexOf(u8, detail, "model: opus") != null);
    try testing.expect(std.mem.indexOf(u8, detail, "user-invocable: true") != null);
    try testing.expect(std.mem.indexOf(u8, detail, "Body line.") != null);
    // The detail view must not include the raw frontmatter fence.
    try testing.expect(std.mem.indexOf(u8, detail, "---\ndescription:") == null);
}

test "list namespaces commands in subdirectories" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Flat command at the root.
    try tmp.dir.createDirPath(rt.io, ".zcode/commands");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/commands/build.md",
        .data = "Build at root.",
    });
    // Namespaced command one level deep.
    try tmp.dir.createDirPath(rt.io, ".zcode/commands/frontend");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/commands/frontend/build.md",
        .data = "Build the frontend.",
    });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(cwd);

    const commands = try list(allocator, cwd);
    defer freeList(allocator, commands);

    try testing.expect(findInList(commands, "build") != null);
    try testing.expect(findInList(commands, "frontend:build") != null);
}

test "list namespaces deeply nested commands with colons" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/commands/a/b");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/commands/a/b/c.md",
        .data = "Deeply nested command.",
    });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(cwd);

    const commands = try list(allocator, cwd);
    defer freeList(allocator, commands);

    try testing.expect(findInList(commands, "a:b:c") != null);
}

test "renderRun resolves a namespaced command" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/commands/frontend");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/commands/frontend/build.md",
        .data = "Build target: {{args}}",
    });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(cwd);

    const rendered = try renderRun(allocator, cwd, "frontend:build", "prod");
    defer allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "Build target: prod") != null);
}
