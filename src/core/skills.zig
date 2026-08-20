const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const bundled = @import("bundled_skills.zig");
const paths = @import("paths.zig");
const arg_sub = @import("argument_substitution.zig");
const display_safe = @import("display_safe.zig");
const skill_types = @import("skill_types.zig");
const skill_listing = @import("skill_listing.zig");
const skill_visibility = @import("skill_visibility.zig");
const command_namespace = @import("command_namespace.zig");
const gitignore = @import("gitignore.zig");

// The skill data model + frontmatter parser live in skill_types.zig (a leaf
// module so the pure transforms are unit-testable and the listing/visibility
// modules can depend on the type without a cycle). Re-export for callers.
pub const SkillScope = skill_types.SkillScope;
pub const SkillContext = skill_types.SkillContext;
pub const SkillSpec = skill_types.SkillSpec;
pub const scopeName = skill_types.scopeName;
pub const freeList = skill_types.freeList;
pub const clone = skill_types.clone;

pub fn list(allocator: std.mem.Allocator, cwd: []const u8) ![]SkillSpec {
    return listWithTouched(allocator, cwd, &.{});
}

/// Like `list`, but also discovers skills in nested `.zcode/skills` (and
/// `.claude/skills`) directories that sit above each path in `touched_files`
/// (skills-04 nested discovery). A skill nested under a touched file's ancestor
/// is loaded with scope `.workspace`; gitignored ancestor dirs are skipped and
/// the walk never escapes `cwd`. Passing an empty `touched_files` is identical
/// to `list`.
pub fn listWithTouched(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    touched_files: []const []const u8,
) ![]SkillSpec {
    var out = std.array_list.Managed(SkillSpec).init(allocator);
    errdefer freeList(allocator, out.items);

    try appendBuiltinSkills(allocator, &out);

    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);

    const user_root = try std.fs.path.join(allocator, &.{ resolved.zcode_home, "skills" });
    defer allocator.free(user_root);
    try appendFromRoot(allocator, &out, user_root, .user);

    const workspace_root = try paths.workspacePathAlloc(allocator, cwd, "skills");
    defer allocator.free(workspace_root);
    try appendFromRoot(allocator, &out, workspace_root, .workspace);

    // Plugin skills: each enabled plugin may ship a skills/ dir under its root.
    appendPluginSkills(allocator, &out, cwd) catch {};

    // skills-04 nested discovery: scan `.zcode/skills` / `.claude/skills` dirs
    // above each touched file. Best-effort -- a discovery error never fails the
    // whole listing.
    discoverNestedSkills(allocator, &out, cwd, touched_files) catch {};

    std.mem.sort(SkillSpec, out.items, {}, lessThan);
    return out.toOwnedSlice();
}

pub fn findByName(allocator: std.mem.Allocator, cwd: []const u8, raw_name: []const u8) !?SkillSpec {
    const requested = std.mem.trim(u8, raw_name, " \t\r\n");
    if (requested.len == 0) return null;

    const skills = try list(allocator, cwd);
    defer freeList(allocator, skills);

    // skills-13: match the canonical name first, then fall back to any alias.
    // Two passes so a canonical-name hit always wins over an alias collision.
    for (skills) |skill| {
        if (std.ascii.eqlIgnoreCase(skill.name, requested)) {
            return try clone(allocator, &skill);
        }
    }
    for (skills) |skill| {
        if (skill_types.matchesNameOrAlias(&skill, requested)) {
            return try clone(allocator, &skill);
        }
    }
    return null;
}

pub fn renderList(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const skills = try list(allocator, cwd);
    defer freeList(allocator, skills);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    if (skills.len == 0) {
        try out.writer().writeAll("skills: none\n");
        return out.toOwnedSlice();
    }

    try out.writer().writeAll("skills:\n");
    for (skills) |skill| {
        // The user-facing list shows user-invocable skills only (a skill with
        // user-invocable: false is model-only). Paths gating is not applied to
        // the explicit list -- the user asked to see them.
        if (!skill.user_invocable) continue;
        // Skill description comes from a markdown frontmatter line
        // a user authored. Sanitize so an embedded ESC / newline /
        // DEL doesn't corrupt the list row.
        const safe_name = try display_safe.sanitize(allocator, skill.name);
        defer allocator.free(safe_name);
        const safe_desc = try display_safe.sanitize(allocator, skill.description);
        defer allocator.free(safe_desc);
        try out.writer().print("- {s} ({s}) [{s}] {s}\n", .{
            safe_name,
            scopeName(skill.scope),
            skill.source_path,
            safe_desc,
        });
    }
    return out.toOwnedSlice();
}

/// Render the model-awareness skill listing: model-visible skills (respecting
/// disable-model-invocation and `paths` gating against `touched_files`),
/// formatted by the listing renderer within `char_budget`. Returns "" when no
/// skills are visible. Injected as a per-turn system-reminder by prompt_engine.
pub fn renderModelListing(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    touched_files: []const []const u8,
    activated: []const []const u8,
    char_budget: usize,
) ![]u8 {
    // skills-04: discover nested .zcode/skills dirs above the touched files so a
    // skill defined deep in the tree surfaces once its directory is in play.
    const skills = try listWithTouched(allocator, cwd, touched_files);
    defer freeList(allocator, skills);

    var visible = std.array_list.Managed(SkillSpec).init(allocator);
    defer visible.deinit(); // shallow: items borrow from `skills`, freed above
    for (skills) |*s| {
        // skills-04: an already-activated conditional skill bypasses the paths
        // gate so it stays visible after its file leaves file_focus.
        if (skill_visibility.isVisibleWithActivation(s, .model, touched_files, activated)) {
            try visible.append(s.*);
        }
    }
    return skill_listing.render(allocator, visible.items, char_budget);
}

/// Merge the names of conditional (`paths`-gated) skills whose globs currently
/// match a touched file into the existing `activated` set, returning a freshly
/// allocated, owned, deduped `[][]u8` (skills-04 sticky activation). The result
/// is bounded to skills that actually exist now (so a stale persisted name for a
/// deleted skill is dropped) plus the still-existing prior activations. The
/// caller owns the result and every string in it.
pub fn computeActivatedConditionalSkills(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    touched_files: []const []const u8,
    activated: []const []const u8,
) ![][]u8 {
    const skills = try list(allocator, cwd);
    defer freeList(allocator, skills);

    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }

    const appendUnique = struct {
        fn call(o: *std.array_list.Managed([]u8), a: std.mem.Allocator, name: []const u8) !void {
            for (o.items) |existing| {
                if (std.ascii.eqlIgnoreCase(existing, name)) return;
            }
            const dup = try a.dupe(u8, name);
            errdefer a.free(dup);
            try o.append(dup);
        }
    }.call;

    for (skills) |*s| {
        if (s.paths.len == 0) continue;
        // Carry over a prior activation only if the skill still exists.
        const was_activated = skill_visibility.isActivated(s.name, activated);
        const matches_now = skill_visibility.matchesAnyPath(s.paths, touched_files);
        if (was_activated or matches_now) {
            try appendUnique(&out, allocator, s.name);
        }
    }

    return out.toOwnedSlice();
}

pub fn renderDetail(allocator: std.mem.Allocator, cwd: []const u8, raw_name: []const u8) ![]u8 {
    var skill = (try findByName(allocator, cwd, raw_name)) orelse return error.SkillNotFound;
    defer skill.deinit(allocator);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    const safe_name = try display_safe.sanitize(allocator, skill.name);
    defer allocator.free(safe_name);
    const safe_desc = try display_safe.sanitize(allocator, skill.description);
    defer allocator.free(safe_desc);
    try out.writer().print("name={s}\n", .{safe_name});
    try out.writer().print("scope={s}\n", .{scopeName(skill.scope)});
    try out.writer().print("source={s}\n", .{skill.source_path});
    try out.writer().print("description={s}\n", .{safe_desc});
    // skills-13: list the skill's aliases (alternate invocation names) when set.
    if (skill.aliases.len > 0) {
        try out.writer().writeAll("aliases=");
        for (skill.aliases, 0..) |alias, i| {
            if (i > 0) try out.writer().writeAll(", ");
            const safe_alias = try display_safe.sanitize(allocator, alias);
            defer allocator.free(safe_alias);
            try out.writer().writeAll(safe_alias);
        }
        try out.writer().writeByte('\n');
    }
    try out.writer().writeAll("\nprompt:\n");
    // Body is intentionally NOT sanitized -- the user explicitly
    // asked for the skill's prompt body, prose may legitimately
    // contain newlines, and the body is delimited by the section
    // header above.
    try out.writer().writeAll(skill.prompt);
    if (!std.mem.endsWith(u8, skill.prompt, "\n")) try out.writer().writeByte('\n');
    return out.toOwnedSlice();
}

pub fn renderRun(allocator: std.mem.Allocator, cwd: []const u8, raw_name: []const u8, args: []const u8, session_id: []const u8) ![]u8 {
    var skill = (try findByName(allocator, cwd, raw_name)) orelse return error.SkillNotFound;
    defer skill.deinit(allocator);

    const trimmed_args = std.mem.trim(u8, args, " \t\r\n");

    // For ALL non-builtin skills, expand $ARGUMENTS-family
    // placeholders first. User and workspace skills are .md files
    // the user dropped in -- if they were originally written for
    // Claude Code they almost certainly use $ARGUMENTS, $0, $1.
    // Builtin skills are zcode-bundled and don't use placeholders,
    // so they keep the simpler "Additional task context" path.
    if (skill.scope == .builtin) {
        // skills-03: builtin skills have no real directory, so ${CLAUDE_SKILL_DIR}
        // is left untouched (visibly unresolved rather than silently blanked) and
        // no base-dir header is added. ${CLAUDE_SESSION_ID} is still substituted.
        const base = if (trimmed_args.len == 0)
            try allocator.dupe(u8, skill.prompt)
        else
            try std.fmt.allocPrint(
                allocator,
                "{s}\n\nAdditional task context:\n{s}\n",
                .{ skill.prompt, trimmed_args },
            );
        defer allocator.free(base);
        return replaceVar(allocator, base, "${CLAUDE_SESSION_ID}", session_id);
    }

    // Non-builtin: substitute placeholders with append=false. We
    // keep the surrounding "Skill: ... Task/context: ..." envelope
    // because it gives the model enough framing to know this is a
    // skill invocation rather than a plain prompt -- but the body
    // itself gets the placeholder expansion.
    // Named args ($foo) from the skill's `arguments:` frontmatter, plus the
    // positional $ARGUMENTS / $1 family.
    const expanded_prompt = try arg_sub.substituteArguments(allocator, skill.prompt, args, false, skill.arg_names);
    defer allocator.free(expanded_prompt);

    // skills-03: substitute ${CLAUDE_SKILL_DIR} / ${CLAUDE_SESSION_ID} in the
    // expanded body so a user skill referencing ./scripts via the skill dir or
    // the session id resolves at invocation. MCP bodies are remote/untrusted, so
    // they skip ${CLAUDE_SKILL_DIR} and the base-dir header (the disk dir is
    // meaningless for them) but still get ${CLAUDE_SESSION_ID}. Mirrors
    // loadSkillsDir.ts:345-374.
    const skill_dir = if (skill.scope == .mcp)
        ""
    else
        std.fs.path.dirname(skill.source_path) orelse "";

    const session_sub = try replaceVar(allocator, expanded_prompt, "${CLAUDE_SESSION_ID}", session_id);
    defer allocator.free(session_sub);

    const dir_sub = if (skill.scope == .mcp)
        try allocator.dupe(u8, session_sub)
    else
        try replaceVar(allocator, session_sub, "${CLAUDE_SKILL_DIR}", skill_dir);
    defer allocator.free(dir_sub);

    const context = if (trimmed_args.len > 0)
        trimmed_args
    else
        "Apply this skill to the current repository state and the user's active task.";

    // Disk skills (.user/.workspace/.plugin) with a real directory get a
    // "Base directory for this skill: <dir>" header first so Read/Grep/bash can
    // reach bundled scripts via an absolute path (loadSkillsDir.ts:345-369).
    const wants_header = skill.scope != .mcp and skill_dir.len > 0;
    if (wants_header) {
        return std.fmt.allocPrint(
            allocator,
            "Base directory for this skill: {s}\n\nSkill: {s}\nSource: {s}\n\nFollow these instructions for the current repository.\n\n{s}\n\nTask/context:\n{s}\n",
            .{ skill_dir, skill.name, skill.source_path, dir_sub, context },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "Skill: {s}\nSource: {s}\n\nFollow these instructions for the current repository.\n\n{s}\n\nTask/context:\n{s}\n",
        .{ skill.name, skill.source_path, dir_sub, context },
    );
}

/// Replace every occurrence of `needle` in `haystack` with `replacement`,
/// returning a freshly-allocated owned slice. A no-op fast path returns a copy
/// when `needle` is absent. Used for the ${CLAUDE_SKILL_DIR} / ${CLAUDE_SESSION_ID}
/// substitutions (skills-03).
fn replaceVar(
    allocator: std.mem.Allocator,
    haystack: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    const count = std.mem.count(u8, haystack, needle);
    if (count == 0) return allocator.dupe(u8, haystack);
    const new_len = haystack.len - needle.len * count + replacement.len * count;
    const out = try allocator.alloc(u8, new_len);
    _ = std.mem.replace(u8, haystack, needle, replacement, out);
    return out;
}

fn appendBuiltinSkills(allocator: std.mem.Allocator, out: *std.array_list.Managed(SkillSpec)) !void {
    for (bundled.skills) |skill| {
        // skills-15 gate: a bundled skill whose `enabled()` returns false (e.g.
        // the authoring-only `skillify` skill when its opt-in is unset) is not
        // registered, so it does not surface in any listing or the run path.
        if (!skill.enabled()) continue;
        const spec = try skill_types.makeBuiltin(allocator, skill.name, skill.description, skill.prompt_template, skill.aliases);
        try upsert(out, allocator, spec);
    }
}

fn appendPluginSkills(allocator: std.mem.Allocator, out: *std.array_list.Managed(SkillSpec), cwd: []const u8) !void {
    const plugins_mod = @import("plugins.zig");
    const plugin_list = try plugins_mod.list(allocator, cwd);
    defer plugins_mod.freeList(allocator, plugin_list);
    for (plugin_list) |plugin| {
        if (!plugin.enabled) continue;
        const skills_dir = std.fs.path.join(allocator, &.{ plugin.root_path, "skills" }) catch continue;
        defer allocator.free(skills_dir);
        appendFromRoot(allocator, out, skills_dir, .plugin) catch continue;
    }
}

/// skills-04 nested discovery. For each touched file, walk up its ancestor
/// directories (within `cwd`) and, for any ancestor that holds a
/// `.zcode/skills` or `.claude/skills` directory, load those skills with scope
/// `.workspace`. The realpath-style name dedup in `upsert` keeps a skill from
/// the top-level workspace root from being shadowed by a nested re-discovery of
/// the same dir (first-wins is the workspace root because it is appended first).
/// Gitignored ancestor dirs are skipped; the walk never escapes `cwd`.
fn discoverNestedSkills(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(SkillSpec),
    cwd: []const u8,
    touched_files: []const []const u8,
) !void {
    if (touched_files.len == 0) return;

    // Track ancestor dirs we have already scanned this call so two touched
    // files in the same subtree do not re-walk the same `.zcode/skills`.
    var seen = std.StringHashMapUnmanaged(void){};
    defer {
        var it = seen.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        seen.deinit(allocator);
    }

    const nested_dirs = [_][]const u8{ ".zcode/skills", ".claude/skills" };

    for (touched_files) |touched| {
        // Resolve the touched path against cwd if it is relative, so the
        // ancestor walk has an absolute base.
        const abs = if (std.fs.path.isAbsolute(touched))
            try allocator.dupe(u8, touched)
        else
            try std.fs.path.join(allocator, &.{ cwd, touched });
        defer allocator.free(abs);

        // Walk up from the file's directory. Stop at cwd (do not escape the
        // workspace root) and cap the depth defensively.
        var dir = std.fs.path.dirname(abs) orelse continue;
        var depth: usize = 0;
        while (depth < 64) : (depth += 1) {
            // Stay within cwd: once we are at or above cwd, scan cwd's ancestor
            // candidates only if dir still starts with cwd.
            if (!std.mem.startsWith(u8, dir, cwd)) break;

            for (nested_dirs) |sub| {
                const skills_dir = try std.fs.path.join(allocator, &.{ dir, sub });
                defer allocator.free(skills_dir);

                // Skip if already scanned this call.
                if (seen.contains(skills_dir)) continue;

                // Skip gitignored ancestor skills dirs.
                if (gitignore.isPathGitignored(allocator, cwd, skills_dir)) continue;

                const key = try allocator.dupe(u8, skills_dir);
                seen.put(allocator, key, {}) catch {
                    allocator.free(key);
                };

                appendFromRoot(allocator, out, skills_dir, .workspace) catch {};
            }

            if (std.mem.eql(u8, dir, cwd)) break;
            const parent = std.fs.path.dirname(dir) orelse break;
            if (std.mem.eql(u8, parent, dir)) break; // reached filesystem root
            dir = parent;
        }
    }
}

fn appendFromRoot(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(SkillSpec),
    root: []const u8,
    scope: SkillScope,
) !void {
    // Start the namespaced walk at the root with an empty prefix. A directory
    // directly under `root` that holds a SKILL.md is a flat skill; one nested
    // under intermediate dirs gets a `parent:...:dir` namespaced name.
    try appendFromDir(allocator, out, root, "", scope, 0);
}

/// Recursive walk of a skills directory. A subdirectory that contains a
/// `SKILL.md` is loaded as a skill named `<prefix>:<dirname>` (or bare
/// `<dirname>` at the root). A subdirectory that does NOT contain a SKILL.md is
/// treated as a namespace container and recursed into, extending the prefix.
/// `prefix` is the `:`-joined chain of parent directory names below the root.
fn appendFromDir(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(SkillSpec),
    dir_path: []const u8,
    prefix: []const u8,
    scope: SkillScope,
    depth: usize,
) !void {
    if (depth > command_namespace.max_depth) return;

    var dir = std.Io.Dir.cwd().openDir(rt.io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return,
        error.AccessDenied => return,
        else => return err,
    };
    defer dir.close(rt.io);

    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        // Symlinked dirs report as .sym_link, not .directory, so this skips them.
        if (entry.kind != .directory) continue;

        // The skill's leaf name is this directory's basename; the namespace is
        // the prefix accumulated from parent directories below the root.
        const skill_name = try command_namespace.join(allocator, prefix, entry.name);
        defer allocator.free(skill_name);

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name, "SKILL.md" });
        defer allocator.free(full_path);
        const skill = loadFile(allocator, full_path, skill_name, scope) catch |err| switch (err) {
            // No SKILL.md here: treat this directory as a namespace container and
            // recurse, extending the prefix with its name.
            error.FileNotFound => {
                const child_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                defer allocator.free(child_path);
                try appendFromDir(allocator, out, child_path, skill_name, scope, depth + 1);
                continue;
            },
            else => return err,
        };
        try upsert(out, allocator, skill);
    }
}

fn upsert(out: *std.array_list.Managed(SkillSpec), allocator: std.mem.Allocator, incoming: SkillSpec) !void {
    for (out.items, 0..) |*existing, idx| {
        if (std.ascii.eqlIgnoreCase(existing.name, incoming.name)) {
            existing.deinit(allocator);
            out.items[idx] = incoming;
            return;
        }
    }
    // On append OOM, free the incoming spec so its interior strings don't leak.
    out.append(incoming) catch |err| {
        var tmp = incoming;
        tmp.deinit(allocator);
        return err;
    };
}

fn loadFile(allocator: std.mem.Allocator, path: []const u8, dirname: []const u8, scope: SkillScope) !SkillSpec {
    const raw = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(raw);
    return skill_types.parse(allocator, raw, dirname, scope, path);
}

fn lessThan(_: void, lhs: SkillSpec, rhs: SkillSpec) bool {
    return std.ascii.lessThanIgnoreCase(lhs.name, rhs.name);
}

const testing = std.testing;

test "renderRun returns builtin prompt with extra args" {
    const rendered = try renderRun(testing.allocator, ".", "debug", "focus on provider auth", "");
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "Help debug the current issue") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "focus on provider auth") != null);
}

test "workspace skill overrides builtin and renders detail" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/skills/debug");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/skills/debug/SKILL.md",
        .data =
        \\# Local Debug
        \\
        \\Follow the local debug workflow.
        ,
    });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const detail = try renderDetail(testing.allocator, cwd, "debug");
    defer testing.allocator.free(detail);

    try testing.expect(std.mem.indexOf(u8, detail, "scope=workspace") != null);
    try testing.expect(std.mem.indexOf(u8, detail, "Follow the local debug workflow.") != null);
}

test "skill in a subdirectory gets a namespaced name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/skills/frontend/deploy");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/skills/frontend/deploy/SKILL.md",
        .data =
        \\# Deploy
        \\
        \\Deploy the frontend.
        ,
    });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const skills = try list(testing.allocator, cwd);
    defer freeList(testing.allocator, skills);

    var found = false;
    for (skills) |skill| {
        if (std.mem.eql(u8, skill.name, "frontend:deploy")) found = true;
    }
    try testing.expect(found);
}

test "skills-04 computeActivatedConditionalSkills marks a matching conditional skill" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/skills/zigfmt");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/skills/zigfmt/SKILL.md",
        .data =
        \\---
        \\name: zigfmt
        \\paths: "*.zig"
        \\---
        \\Format the zig files.
        ,
    });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Turn 1: a *.zig file is touched -> the skill activates.
    {
        const touched = [_][]const u8{"src/main.zig"};
        const activated = try computeActivatedConditionalSkills(testing.allocator, cwd, &touched, &.{});
        defer {
            for (activated) |a| testing.allocator.free(a);
            testing.allocator.free(activated);
        }
        try testing.expect(skill_visibility.isActivated("zigfmt", activated));
    }

    // Turn 2: file_focus no longer matches, but the prior activation is sticky.
    {
        const non_match = [_][]const u8{"docs/readme.md"};
        const prior = [_][]const u8{"zigfmt"};
        const activated = try computeActivatedConditionalSkills(testing.allocator, cwd, &non_match, &prior);
        defer {
            for (activated) |a| testing.allocator.free(a);
            testing.allocator.free(activated);
        }
        try testing.expect(skill_visibility.isActivated("zigfmt", activated));
    }

    // A stale prior activation for a skill that does not exist is dropped.
    {
        const non_match = [_][]const u8{"docs/readme.md"};
        const stale = [_][]const u8{"ghost"};
        const activated = try computeActivatedConditionalSkills(testing.allocator, cwd, &non_match, &stale);
        defer {
            for (activated) |a| testing.allocator.free(a);
            testing.allocator.free(activated);
        }
        try testing.expect(!skill_visibility.isActivated("ghost", activated));
    }
}

test "skills-04 nested discovery surfaces a skill in a subdir .zcode/skills" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A skill defined deep in the tree, not under the top-level .zcode/skills.
    try tmp.dir.createDirPath(rt.io, "sub/dir");
    try tmp.dir.createDirPath(rt.io, "sub/.zcode/skills/foo");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "sub/.zcode/skills/foo/SKILL.md",
        .data =
        \\# Foo
        \\
        \\The nested foo skill.
        ,
    });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Make the tmp dir its own git repo so the nested-discovery gitignore probe
    // (`git check-ignore`, run from cwd) resolves against THIS repo and not the
    // outer repo whose .gitignore ignores the .zig-cache tmp tree the test runs
    // inside. Without this, every path under cwd is reported ignored and nested
    // discovery is (correctly, but unhelpfully for the test) skipped. If git is
    // unavailable, isPathGitignored fails open ("not ignored") so the test still
    // exercises the walk.
    if (std.process.run(testing.allocator, rt.io, .{
        .argv = &.{ "git", "init", "-q" },
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    })) |res| {
        testing.allocator.free(res.stdout);
        testing.allocator.free(res.stderr);
    } else |_| {}

    // Without touching a nested file, foo is not discovered.
    {
        const skills = try list(testing.allocator, cwd);
        defer freeList(testing.allocator, skills);
        var found = false;
        for (skills) |s| {
            if (std.mem.eql(u8, s.name, "foo")) found = true;
        }
        try testing.expect(!found);
    }

    // Touching sub/dir/file.zig surfaces the ancestor's nested skill.
    {
        const touched = [_][]const u8{"sub/dir/file.zig"};
        const skills = try listWithTouched(testing.allocator, cwd, &touched);
        defer freeList(testing.allocator, skills);
        var found = false;
        for (skills) |s| {
            if (std.mem.eql(u8, s.name, "foo")) found = true;
        }
        try testing.expect(found);
    }
}

test "skills-03 renderRun substitutes CLAUDE_SKILL_DIR and CLAUDE_SESSION_ID and prepends base-dir header" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/skills/runner");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/skills/runner/SKILL.md",
        .data =
        \\# Runner
        \\
        \\Run ${CLAUDE_SKILL_DIR}/scripts/run.sh in session ${CLAUDE_SESSION_ID}.
        ,
    });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const rendered = try renderRun(testing.allocator, cwd, "runner", "", "sess-123");
    defer testing.allocator.free(rendered);

    // (a) ${CLAUDE_SKILL_DIR} resolves to the skill's own absolute directory.
    const expected_dir = try std.fs.path.join(testing.allocator, &.{ cwd, ".zcode", "skills", "runner" });
    defer testing.allocator.free(expected_dir);
    const expected_script = try std.fmt.allocPrint(testing.allocator, "{s}/scripts/run.sh", .{expected_dir});
    defer testing.allocator.free(expected_script);
    try testing.expect(std.mem.indexOf(u8, rendered, expected_script) != null);
    // The literal placeholder must be gone.
    try testing.expect(std.mem.indexOf(u8, rendered, "${CLAUDE_SKILL_DIR}") == null);

    // (b) ${CLAUDE_SESSION_ID} resolves to the passed session id.
    try testing.expect(std.mem.indexOf(u8, rendered, "session sess-123.") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "${CLAUDE_SESSION_ID}") == null);

    // (c) the rendered output carries the base-dir header for a disk skill.
    const header = try std.fmt.allocPrint(testing.allocator, "Base directory for this skill: {s}", .{expected_dir});
    defer testing.allocator.free(header);
    try testing.expect(std.mem.indexOf(u8, rendered, header) != null);
    // The header is the very first line.
    try testing.expect(std.mem.startsWith(u8, rendered, "Base directory for this skill: "));
}

test "skills-03 builtin skill renders unchanged with no base-dir header" {
    // (e) A builtin skill (no real directory) gets no base-dir header and the
    // ${CLAUDE_SKILL_DIR} literal is left untouched; ${CLAUDE_SESSION_ID} still
    // substitutes. `debug` is a bundled skill that does not reference the vars,
    // so its body is unchanged.
    const rendered = try renderRun(testing.allocator, ".", "debug", "", "sess-xyz");
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "Base directory for this skill:") == null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Help debug the current issue") != null);
}

test "skills-07 skillify is absent from list() when the authoring gate is off" {
    // The test process does not set ZCODE_ENABLE_SKILLIFY, so the gate is off
    // and skillify must not appear in the listing (acceptance criterion b).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const skills = try list(testing.allocator, cwd);
    defer freeList(testing.allocator, skills);

    var found_skillify = false;
    var found_debug = false;
    for (skills) |s| {
        if (std.ascii.eqlIgnoreCase(s.name, "skillify")) found_skillify = true;
        if (std.ascii.eqlIgnoreCase(s.name, "debug")) found_debug = true;
    }
    try testing.expect(!found_skillify);
    // The always-on bundled skills are still present.
    try testing.expect(found_debug);
}

test "skills-13 findByName resolves a workspace skill via its alias; canonical name still wins on listing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/skills/committer");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/skills/committer/SKILL.md",
        .data =
        \\---
        \\name: committer
        \\description: make a commit
        \\aliases: cmt, ci
        \\---
        \\Make a commit.
        ,
    });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // The skill is found by an alias.
    {
        var found = (try findByName(testing.allocator, cwd, "ci")) orelse return error.TestUnexpectedResult;
        defer found.deinit(testing.allocator);
        try testing.expectEqualStrings("committer", found.name);
    }
    // ...and by its other alias, case-insensitively.
    {
        var found = (try findByName(testing.allocator, cwd, "CMT")) orelse return error.TestUnexpectedResult;
        defer found.deinit(testing.allocator);
        try testing.expectEqualStrings("committer", found.name);
    }
    // The canonical name still resolves.
    {
        var found = (try findByName(testing.allocator, cwd, "committer")) orelse return error.TestUnexpectedResult;
        defer found.deinit(testing.allocator);
        try testing.expectEqualStrings("committer", found.name);
    }
    // A non-alias, non-name string does not resolve.
    {
        const found = try findByName(testing.allocator, cwd, "nope");
        try testing.expect(found == null);
    }

    // The listing sorts/lists by the canonical name (the alias is not a row).
    {
        const skills = try list(testing.allocator, cwd);
        defer freeList(testing.allocator, skills);
        var has_canonical = false;
        var has_alias_row = false;
        for (skills) |s| {
            if (std.mem.eql(u8, s.name, "committer")) has_canonical = true;
            if (std.mem.eql(u8, s.name, "ci") or std.mem.eql(u8, s.name, "cmt")) has_alias_row = true;
        }
        try testing.expect(has_canonical);
        try testing.expect(!has_alias_row);
    }
}

test "skills-03 replaceVar substitutes all occurrences and no-ops when absent" {
    {
        const out = try replaceVar(testing.allocator, "a ${V} b ${V} c", "${V}", "X");
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("a X b X c", out);
    }
    {
        const out = try replaceVar(testing.allocator, "nothing here", "${V}", "X");
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("nothing here", out);
    }
    {
        // Empty replacement (the builtin / mcp-skip-dir behavior would never call
        // this, but the dir-skip for builtins leaves the literal untouched -- this
        // just exercises an empty replacement string).
        const out = try replaceVar(testing.allocator, "x${V}y", "${V}", "");
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("xy", out);
    }
}
