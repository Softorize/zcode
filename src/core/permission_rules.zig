const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const settings_sources = @import("settings_sources.zig");
const env_mod = @import("env.zig");
const mcp_name = @import("mcp_name.zig");

pub const Action = enum {
    allow,
    deny,
    ask,

    pub fn parse(raw: []const u8) ?Action {
        if (std.ascii.eqlIgnoreCase(raw, "allow")) return .allow;
        if (std.ascii.eqlIgnoreCase(raw, "deny")) return .deny;
        if (std.ascii.eqlIgnoreCase(raw, "ask")) return .ask;
        return null;
    }

    pub fn toString(self: Action) []const u8 {
        return switch (self) {
            .allow => "allow",
            .deny => "deny",
            .ask => "ask",
        };
    }
};

pub const ScopeSpec = union(enum) {
    global,
    workspace: []const u8,
};

pub const Scope = union(enum) {
    global,
    workspace: []u8,

    fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .global => {},
            .workspace => |path| allocator.free(path),
        }
    }

    fn clone(allocator: std.mem.Allocator, spec: ScopeSpec) !Scope {
        return switch (spec) {
            .global => .global,
            .workspace => |path| .{ .workspace = try allocator.dupe(u8, path) },
        };
    }
};

pub const Rule = struct {
    action: Action,
    scope: Scope,
    tool: []u8,
    args_contains: []u8,
    source_path: []u8,
    source_line: usize,
    source_label: []u8,

    pub fn deinit(self: *Rule, allocator: std.mem.Allocator) void {
        self.scope.deinit(allocator);
        allocator.free(self.tool);
        allocator.free(self.args_contains);
        allocator.free(self.source_path);
        allocator.free(self.source_label);
    }
};

pub const Match = struct {
    index: usize,
    rule: *const Rule,
};

/// Result of `Store.decide`: the winning behavior class plus the matched rule.
/// `match` borrows a pointer into `Store.rules.items` (same lifetime contract as
/// `Store.match`); do not free it.
pub const DecideResult = struct {
    action: Action,
    match: Match,
};

/// A single tool + args_contains pair for a `Store.replaceRules` call. An empty
/// `args_contains` ("") is the tool-wide form (matches any args). Slices are
/// borrowed for the duration of the `replaceRules` call; `addRule` dupes them.
pub const RuleSpec = struct {
    tool: []const u8,
    args_contains: []const u8 = "",
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    rules: std.array_list.Managed(Rule),

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .allocator = allocator,
            .rules = std.array_list.Managed(Rule).init(allocator),
        };
    }

    pub fn deinit(self: *Store) void {
        self.clear();
        self.rules.deinit();
    }

    pub fn clear(self: *Store) void {
        for (self.rules.items) |*rule| rule.deinit(self.allocator);
        self.rules.clearRetainingCapacity();
    }

    pub fn reloadFromFile(self: *Store, path: []const u8) !bool {
        self.clear();
        return self.loadFromFile(path);
    }

    pub fn loadFromFile(self: *Store, path: []const u8) !bool {
        const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, self.allocator, .limited(512 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer self.allocator.free(bytes);

        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw_line| {
            line_no += 1;
            // Per-rule salvage (settings-07, mirrors the reference
            // `filterInvalidPermissionRules`): a single malformed rule is
            // skipped with a warning, not fatal, so the rest of the file still
            // loads. Only `error.InvalidPermissionRule` (the syntactic-validity
            // class from parseScope/Action.parse/validateField) is salvaged;
            // genuinely fatal errors (OOM) propagate.
            self.parseLine(path, line_no, raw_line) catch |err| switch (err) {
                error.InvalidPermissionRule => {
                    const content = std.mem.trim(u8, raw_line, " \t\r\n");
                    std.log.warn(
                        "permission_rules: skipped malformed rule at {s}:{d}: {s}",
                        .{ path, line_no, content },
                    );
                    continue;
                },
                else => return err,
            };
        }

        return true;
    }

    /// Load permission rules from each settings.json source's
    /// `permissions.{allow,deny,ask}` arrays and append them to this Store.
    /// Mirrors the reference `settingsJsonToRules` (permissionsLoader.ts:91-114)
    /// + `loadAllPermissionRulesFromDisk` (permissionsLoader.ts:120-133).
    ///
    /// Walks the disk-backed PermissionRuleSource order
    /// (policy/flag/user/project/local). The cli_arg/command/session sources are
    /// populated at runtime by later phases, not from disk.
    ///
    /// When the policy source sets `allowManagedPermissionRulesOnly: true`
    /// (permissionsLoader.ts:31-44), only the policy source's arrays are loaded
    /// (all other sources are short-circuited).
    ///
    /// Scope mapping: project/local arrays are workspace-scoped to `cwd`;
    /// policy/flag/user arrays are global. Malformed entries are skipped, never
    /// fatal (the reference does not strictly validate rule strings on read).
    pub fn loadFromSettingsJson(
        self: *Store,
        allocator: std.mem.Allocator,
        cwd: []const u8,
        flag_path: ?[]const u8,
    ) !void {
        const managed_only = settings_sources.sourceScalarBool(
            allocator,
            cwd,
            flag_path,
            .policy,
            "allowManagedPermissionRulesOnly",
        ) orelse false;

        // Disk-backed sources only; runtime sources (cli_arg/command/session)
        // are populated elsewhere. Iterate as `Source` so we can call readSource.
        const disk_sources = [_]settings_sources.Source{ .policy, .flag, .user, .project, .local };
        for (disk_sources) |source| {
            if (managed_only and source != .policy) continue;
            try self.loadSourceRules(allocator, cwd, source, flag_path);
        }
    }

    fn loadSourceRules(
        self: *Store,
        allocator: std.mem.Allocator,
        cwd: []const u8,
        source: settings_sources.Source,
        flag_path: ?[]const u8,
    ) !void {
        var parsed = (settings_sources.readSource(allocator, cwd, source, flag_path) catch null) orelse return;
        defer parsed.deinit();

        const perms = settings_sources.getObject(parsed.value, "permissions") orelse return;

        const label = source.displayName();
        const path = (try settings_sources.sourcePath(allocator, cwd, source, flag_path)) orelse "";
        defer if (path.len > 0) allocator.free(path);

        const scope: ScopeSpec = switch (source) {
            .project, .local => .{ .workspace = cwd },
            .policy, .flag, .user => .global,
        };

        const arrays = [_]struct { key: []const u8, action: Action }{
            .{ .key = "allow", .action = .allow },
            .{ .key = "deny", .action = .deny },
            .{ .key = "ask", .action = .ask },
        };
        for (arrays) |entry| {
            const list = settings_sources.getArray(perms, entry.key) orelse continue;
            for (list) |item| {
                const rule_str = switch (item) {
                    .string => |s| s,
                    // Tolerate malformed (non-string) entries: skip, do not fail.
                    else => continue,
                };
                self.addSettingsRule(entry.action, scope, rule_str, path, label) catch continue;
            }
        }
    }

    /// Parse a single reference rule string (`ToolName` or `ToolName(content)`,
    /// or an `mcp__server__tool` MCP rule) and append it. MCP rules store the
    /// whole normalized name as the tool with empty args_contains (no `(` split)
    /// so they line up with Task 3's `buildMcpToolName` keying.
    fn addSettingsRule(
        self: *Store,
        action: Action,
        scope: ScopeSpec,
        rule_str: []const u8,
        source_path: []const u8,
        source_label: []const u8,
    ) !void {
        const trimmed = std.mem.trim(u8, rule_str, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidPermissionRule;

        // MCP rule: keep the whole name as the tool, no args split.
        if (std.mem.startsWith(u8, trimmed, "mcp__")) {
            try self.addRule(action, scope, trimmed, "", source_path, 0, source_label);
            return;
        }

        // Split on the first '(' into tool + args_contains (drop trailing ')').
        if (std.mem.indexOfScalar(u8, trimmed, '(')) |open| {
            const tool = std.mem.trim(u8, trimmed[0..open], " \t");
            var content = trimmed[open + 1 ..];
            if (content.len > 0 and content[content.len - 1] == ')') {
                content = content[0 .. content.len - 1];
            }
            try self.addRule(action, scope, tool, content, source_path, 0, source_label);
            return;
        }

        try self.addRule(action, scope, trimmed, "", source_path, 0, source_label);
    }

    pub fn saveToFile(self: *const Store, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |dir| {
            try std.Io.Dir.cwd().createDirPath(rt.io, dir);
        }

        var out = std_io.StringBuilder.init(self.allocator);
        defer out.deinit();
        const writer = out.writer();
        try writer.writeAll("# zcode permission rules v1\n");
        try writer.writeAll("# action\tscope\ttool\targs_contains\tsource\n");
        for (self.rules.items) |rule| {
            try writer.print("{s}\t", .{rule.action.toString()});
            switch (rule.scope) {
                .global => try writer.writeAll("global"),
                .workspace => |path_buf| try writer.print("workspace:{s}", .{path_buf}),
            }
            try writer.print("\t{s}\t{s}\t{s}\n", .{ rule.tool, rule.args_contains, rule.source_label });
        }

        const bytes = try out.toOwnedSlice();
        defer self.allocator.free(bytes);
        try writeFileAtomic(self.allocator, path, bytes);
    }

    pub fn addRule(
        self: *Store,
        action: Action,
        scope: ScopeSpec,
        tool: []const u8,
        args_contains: []const u8,
        source_path: []const u8,
        source_line: usize,
        source_label: []const u8,
    ) !void {
        try validateField("tool", tool, false);
        try validateField("args_contains", args_contains, true);
        try validateField("source_path", source_path, true);
        try validateField("source_label", source_label, false);
        switch (scope) {
            .global => {},
            .workspace => |path| try validateField("workspace", path, false),
        }

        var rule = Rule{
            .action = action,
            .scope = try Scope.clone(self.allocator, scope),
            .tool = try self.allocator.dupe(u8, tool),
            .args_contains = try self.allocator.dupe(u8, args_contains),
            .source_path = try self.allocator.dupe(u8, source_path),
            .source_line = source_line,
            .source_label = try self.allocator.dupe(u8, source_label),
        };
        errdefer rule.deinit(self.allocator);
        try self.rules.append(rule);
    }

    pub fn removeAt(self: *Store, index: usize) !void {
        if (index >= self.rules.items.len) return error.PermissionRuleNotFound;
        var removed = self.rules.orderedRemove(index);
        removed.deinit(self.allocator);
    }

    /// P3 (PRD #534): remove every `allow` rule whose tool is the canonical bash
    /// tool ("Bash") and whose content (`args_contains`) the dangerous-permission
    /// predicate flags, returning the removed rules (owned by the caller) as a
    /// stash so the mode-transition code can restore them on exit.
    ///
    /// Mirrors the reference `stripDangerousPermissionsForAutoMode`
    /// (permissionSetup.ts:510-553): the in-memory context is cleaned and the
    /// dangerous rules are stashed for later restoration. This operates on the
    /// in-memory store ONLY (no file save), matching the reference which mutates
    /// the in-memory context by default. Persisting would clobber the user's
    /// `Bash(*)` rule permanently across sessions.
    ///
    /// Ownership: `orderedRemove` returns each Rule by value WITHOUT freeing its
    /// owned slices; the moved Rule is appended to the returned stash, so its
    /// allocations transfer to the caller. The caller must eventually pass the
    /// stash back to `restoreStashed` (which moves the rules home) -- it must NOT
    /// deinit the stashed rules itself, or the slices would be double-freed.
    pub fn stripDangerous(self: *Store, allocator: std.mem.Allocator) ![]Rule {
        const dangerous_permissions = @import("dangerous_permissions.zig");

        var stash = std.array_list.Managed(Rule).init(allocator);
        errdefer {
            // On failure, move the already-captured rules back so the store stays
            // whole. (We have not freed anything yet, just relocated it.)
            for (stash.items) |rule| self.rules.append(rule) catch {};
            stash.deinit();
        }

        // Reverse-iterate so orderedRemove indices stay valid as we drop entries.
        var index = self.rules.items.len;
        while (index > 0) {
            index -= 1;
            const rule = &self.rules.items[index];
            if (rule.action != .allow) continue;
            if (!std.mem.eql(u8, rule.tool, "Bash")) continue;
            if (!dangerous_permissions.isDangerousBashContent(rule.args_contains)) continue;

            // Move the Rule out by value (no free) and capture it in the stash.
            const removed = self.rules.orderedRemove(index);
            std.log.debug(
                "permission_rules: stripping dangerous allow rule Bash({s}) for restrictive mode",
                .{removed.args_contains},
            );
            try stash.append(removed);
        }

        return try stash.toOwnedSlice();
    }

    /// P3 (PRD #534): re-append the stashed rules (transferring ownership back
    /// into the store) and free the stash slice. Mirrors the reference
    /// `restoreDangerousPermissions` (permissionSetup.ts:561-579): the stashed
    /// rules are re-added and the stash cleared, so a second exit (an empty stash)
    /// is a no-op.
    ///
    /// Ownership: each stashed Rule still owns its slices (they were moved out by
    /// `stripDangerous` without freeing). Appending the value moves them home; do
    /// NOT re-dupe. The stash slice itself is freed here.
    pub fn restoreStashed(self: *Store, stash: []Rule) !void {
        // Reserve up front so every append below is infallible: a partial
        // failure mid-loop would otherwise strand the un-appended rules (whose
        // slices the caller is contractually told not to free).
        try self.rules.ensureUnusedCapacity(stash.len);
        for (stash) |rule| {
            self.rules.appendAssumeCapacity(rule);
        }
        self.allocator.free(stash);
    }

    /// Bulk-replace every rule of a given `action`+`source_label` (regardless of
    /// scope or position) with `new_rules`, all carrying the same `action`,
    /// `scope`, and `source_label`. Mirrors the reference `replaceRules`
    /// (PermissionUpdate.ts:97-120): the old set for that behavior+source is
    /// dropped wholesale and the new set appended.
    ///
    /// Only rules whose action AND source_label match are removed -- rules of
    /// other actions, or from other sources, are left untouched. The new rules
    /// are appended in the order given. Each `new_rules[i]` is the tool +
    /// args_contains pair for one rule (empty `args_contains` means tool-wide).
    pub fn replaceRules(
        self: *Store,
        action: Action,
        scope: ScopeSpec,
        source_label: []const u8,
        new_rules: []const RuleSpec,
    ) !void {
        // Remove every existing rule of this action+source_label. Iterate from
        // the end so removeAt indices stay valid as we drop entries.
        var index = self.rules.items.len;
        while (index > 0) {
            index -= 1;
            const rule = &self.rules.items[index];
            if (rule.action != action) continue;
            if (!std.mem.eql(u8, rule.source_label, source_label)) continue;
            try self.removeAt(index);
        }

        // Append the new set. addRule dupes/validates each field and
        // errdefers its own partial allocation, so a failure mid-loop leaves
        // the store consistent (already-appended specs simply remain).
        for (new_rules) |spec| {
            try self.addRule(action, scope, spec.tool, spec.args_contains, "", 0, source_label);
        }
    }

    /// Reverse-iterate and return the LAST-defined rule of ANY action that
    /// matches. This reports the last matching rule for debugging
    /// (`/permissions explain`) and is DISTINCT from the precedence used at
    /// enforcement: see `decide` for the deny-wins-then-ask-then-allow
    /// behavior-class precedence the tool gate actually applies.
    pub fn match(self: *const Store, cwd: []const u8, tool: []const u8, args: []const u8) ?Match {
        var remaining = self.rules.items.len;
        while (remaining > 0) {
            remaining -= 1;
            const rule = &self.rules.items[remaining];
            if (!ruleMatches(rule, cwd, tool, args)) continue;
            return .{ .index = remaining, .rule = rule };
        }
        return null;
    }

    /// Behavior-class precedence: scan ALL deny rules first (regardless of list
    /// position), then ALL ask rules, then ALL allow rules, returning the first
    /// match within the winning class. A deny rule anywhere beats an allow rule
    /// anywhere, and an ask rule beats an allow rule. Mirrors the reference
    /// `hasPermissionsToUseToolInner` ordering (permissions.ts:1169-1297, steps
    /// 1a deny / 1b ask / 2b allow). Forward order within a class matches the
    /// reference's `.find` over the source-concatenation order. Returns null when
    /// nothing matches. The returned `match.rule` borrows a pointer into
    /// `self.rules.items` (same lifetime contract as `match`).
    pub fn decide(self: *const Store, cwd: []const u8, tool: []const u8, args: []const u8) ?DecideResult {
        const order = [_]Action{ .deny, .ask, .allow };
        for (order) |want| {
            for (self.rules.items, 0..) |*rule, index| {
                if (rule.action != want) continue;
                if (!ruleMatches(rule, cwd, tool, args)) continue;
                return .{ .action = want, .match = .{ .index = index, .rule = rule } };
            }
        }
        return null;
    }

    /// Skill-tool permission decision (skills-02). Mirrors `decide`'s
    /// deny-then-ask-then-allow behavior-class precedence, but matches a rule's
    /// content against a SKILL NAME rather than the serialized JSON tool args.
    /// A rule participates only when its tool is `Skill` (or `*`). Its content
    /// matches the skill name when:
    ///   - content is empty           -> tool-wide `Skill` rule, matches any name
    ///   - content == name            -> exact match
    ///   - content == "<prefix>:*"    -> name starts with "<prefix>" (the
    ///                                    reference's `name:*` prefix form,
    ///                                    SkillTool.ts ruleMatches), normalized
    ///                                    so the `:` separator is not treated as
    ///                                    a literal glob char
    ///   - content is a glob          -> standard `*`/`?` whole-name match
    /// The returned `match.rule` borrows into `self.rules.items`.
    pub fn decideSkill(self: *const Store, cwd: []const u8, skill_name: []const u8) ?DecideResult {
        const order = [_]Action{ .deny, .ask, .allow };
        for (order) |want| {
            for (self.rules.items, 0..) |*rule, index| {
                if (rule.action != want) continue;
                if (!scopeMatches(rule.scope, cwd)) continue;
                if (!toolMatches(rule.tool, "Skill")) continue;
                if (!skillContentMatches(rule.args_contains, skill_name)) continue;
                return .{ .action = want, .match = .{ .index = index, .rule = rule } };
            }
        }
        return null;
    }

    /// Return true if a deny rule blocks the `agent_type` sub-agent in `cwd`.
    /// Mirrors the reference `getDenyRuleForAgent` (permissions.ts:304-322): a
    /// deny rule matches an agent when its tool is `"Agent"` and its content
    /// (`args_contains`) EXACTLY equals the agent type. The match is exact, not
    /// a glob/substring -- an agent type is an identity, not a pattern. Scope is
    /// honored (a workspace-scoped deny only applies inside that workspace).
    pub fn isAgentDenied(self: *const Store, cwd: []const u8, agent_type: []const u8) bool {
        for (self.rules.items) |*rule| {
            if (rule.action != .deny) continue;
            if (!scopeMatches(rule.scope, cwd)) continue;
            if (!std.mem.eql(u8, rule.tool, "Agent")) continue;
            if (std.mem.eql(u8, rule.args_contains, agent_type)) return true;
        }
        return false;
    }

    /// Invoke `callback` once per distinct denied agent type in `cwd`.
    /// Mirrors the reference `filterDeniedAgents` (permissions.ts:324-343): it
    /// collects every `Agent(content)` deny rule's content. A callback iterator
    /// avoids allocation; the slice passed to `callback` borrows into the rule
    /// store and must not be retained past the call. Tool-wide `Agent` deny
    /// rules (empty content) are skipped -- they are not agent-type identities.
    pub fn deniedAgentTypes(
        self: *const Store,
        cwd: []const u8,
        ctx: anytype,
        comptime callback: fn (@TypeOf(ctx), []const u8) void,
    ) void {
        for (self.rules.items) |*rule| {
            if (rule.action != .deny) continue;
            if (!scopeMatches(rule.scope, cwd)) continue;
            if (!std.mem.eql(u8, rule.tool, "Agent")) continue;
            if (rule.args_contains.len == 0) continue;
            callback(ctx, rule.args_contains);
        }
    }

    fn parseLine(self: *Store, source_path: []const u8, line_no: usize, raw_line: []const u8) !void {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0 or line[0] == '#') return;

        var fields: [5][]const u8 = undefined;
        var count: usize = 0;
        var parts = std.mem.splitScalar(u8, line, '\t');
        while (parts.next()) |part| {
            if (count >= fields.len) return error.InvalidPermissionRule;
            fields[count] = part;
            count += 1;
        }
        if (count != fields.len) return error.InvalidPermissionRule;

        const action = Action.parse(fields[0]) orelse return error.InvalidPermissionRule;
        const scope = try parseScope(fields[1]);
        try self.addRule(action, scope, fields[2], fields[3], source_path, line_no, fields[4]);
    }
};

/// Shared predicate: does `rule` apply to `tool`/`args` in `cwd`?
/// `args_contains.len == 0` is the tool-wide form (matches any args), mirroring
/// the reference's `ruleContent === undefined`.
fn ruleMatches(rule: *const Rule, cwd: []const u8, tool: []const u8, args: []const u8) bool {
    if (!scopeMatches(rule.scope, cwd)) return false;
    if (!toolMatches(rule.tool, tool)) return false;
    if (rule.args_contains.len > 0 and !argsMatch(rule.args_contains, args)) return false;
    return true;
}

fn parseScope(raw: []const u8) !ScopeSpec {
    if (std.mem.eql(u8, raw, "global")) return .global;
    const prefix = "workspace:";
    if (std.mem.startsWith(u8, raw, prefix)) {
        const path = raw[prefix.len..];
        if (path.len == 0) return error.InvalidPermissionRule;
        return .{ .workspace = path };
    }
    return error.InvalidPermissionRule;
}

fn toolMatches(pattern: []const u8, tool: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*") or std.mem.eql(u8, pattern, tool)) return true;

    // MCP server-level / glob matching: a rule whose tool is `mcp__server`
    // (server-level, no tool component) or `mcp__server__*` matches every tool
    // from that server. Guard behind "both parse as MCP" so a plain `Bash` rule
    // never matches an `mcp__server__tool` tool. Mirrors the reference
    // `toolMatchesRule` MCP branch (permissions.ts:238-269). zcode uses the
    // canonical `mcp__server__tool` scheme (see core/mcp_name.zig), not `mcp::`.
    const pattern_info = mcp_name.mcpInfoFromString(pattern) orelse return false;
    const tool_info = mcp_name.mcpInfoFromString(tool) orelse return false;
    if (!std.mem.eql(u8, pattern_info.server, tool_info.server)) return false;
    // `mcp__server` parses to tool == null; `mcp__server__*` parses to tool == "*".
    // Both forms match all of the server's tools.
    if (pattern_info.tool) |pt| {
        return std.mem.eql(u8, pt, "*");
    }
    return true;
}

/// Match a rule's args pattern against the serialized tool args. When the
/// pattern contains a `*` it is treated as a Claude Code-style glob (e.g.
/// `git commit:*`); otherwise it keeps the legacy substring-containment
/// semantics so existing rules behave unchanged. (PRD #534 P2)
fn argsMatch(pattern: []const u8, args: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '*') != null) return globContains(pattern, args);
    return std.mem.indexOf(u8, args, pattern) != null;
}

/// Match a `Skill` rule's content against a skill NAME (skills-02). An empty
/// content is the tool-wide form (matches any name). A `<prefix>:*` content is
/// the reference's name-prefix form: the trailing `:*` is normalized to a bare
/// `*` so the `:` separator is treated as the rule-content delimiter, not a
/// literal glob char, giving `foo:*` a `foo*` prefix match. Any other content
/// is treated as a whole-name glob (`*`/`?`), falling back to exact equality
/// when it carries no wildcard.
fn skillContentMatches(content: []const u8, skill_name: []const u8) bool {
    if (content.len == 0) return true;
    if (std.mem.eql(u8, content, skill_name)) return true;
    if (std.mem.endsWith(u8, content, ":*")) {
        const prefix = content[0 .. content.len - ":*".len];
        return std.mem.startsWith(u8, skill_name, prefix);
    }
    if (std.mem.indexOfScalar(u8, content, '*') != null or std.mem.indexOfScalar(u8, content, '?') != null) {
        return globMatch(content, skill_name);
    }
    return false;
}

/// Unanchored glob: true if `pattern` matches starting at SOME offset in `text`.
/// `globMatch` is whole-string anchored, but the tool args we match against are
/// the serialized JSON input (e.g. {"command":"git status"}), so an anchored
/// pattern like `git *` would never match. Trying every start offset makes the
/// literal float, while a trailing non-`*` still anchors the end. A pattern that
/// already starts with `*` is matched anchored (its leading `*` floats it).
/// PRD #534 review fix; shared with the hook matcher. No allocation.
pub fn globContains(pattern: []const u8, text: []const u8) bool {
    if (pattern.len > 0 and pattern[0] == '*') return globMatch(pattern, text);
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (globMatch(pattern, text[i..])) return true;
    }
    return false;
}

/// Wildcard match supporting `*` (any run, incl. empty) and `?` (one char).
/// Two-pointer with backtracking; no allocation. Public so the hook matcher
/// (PRD #534 P3) reuses one glob implementation instead of duplicating it.
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            mark = t;
            p += 1;
        } else if (p < pattern.len and (pattern[p] == text[t] or pattern[p] == '?')) {
            p += 1;
            t += 1;
        } else if (star) |s| {
            p = s + 1;
            mark += 1;
            t = mark;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn scopeMatches(scope: Scope, cwd: []const u8) bool {
    return switch (scope) {
        .global => true,
        .workspace => |root| pathWithin(cwd, root),
    };
}

/// True when `path` equals `root` or is a descendant of it (segment-aligned,
/// so `/a/b` is NOT within `/a/bc`). Exposed `pub` so the bash cwd-reset guard
/// (bash-shell-12) can reuse the same containment test the workspace scope match
/// uses, keeping "inside the project" defined identically in both places.
pub fn pathWithin(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (root.len == 0 or path.len <= root.len) return false;
    if (isPathSep(root[root.len - 1])) return true;
    return isPathSep(path[root.len]);
}

fn isPathSep(ch: u8) bool {
    return ch == '/' or ch == '\\';
}

fn validateField(name: []const u8, value: []const u8, allow_empty: bool) !void {
    _ = name;
    if (!allow_empty and value.len == 0) return error.InvalidPermissionRule;
    if (std.mem.indexOfAny(u8, value, "\t\r\n") != null) return error.InvalidPermissionRule;
}

fn writeFileAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{target});
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {};
    }

    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

const testing = std.testing;

test "permission rules use last matching rule and source tracking" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.deny, .global, "Bash", "rm -rf", "rules.tsv", 3, "test");
    try store.addRule(.allow, .global, "Bash", "zig build test", "rules.tsv", 4, "test");

    const denied = store.match("/repo", "Bash", "rm -rf build").?;
    try testing.expectEqual(@as(usize, 0), denied.index);
    try testing.expectEqual(Action.deny, denied.rule.action);
    try testing.expectEqual(@as(usize, 3), denied.rule.source_line);

    const allowed = store.match("/repo", "Bash", "zig build test").?;
    try testing.expectEqual(@as(usize, 1), allowed.index);
    try testing.expectEqual(Action.allow, allowed.rule.action);
}

test "decide: deny wins over a later allow (load-bearing divergence from match)" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    // deny FIRST, allow SECOND. Under latest-wins, match() returns the allow
    // (it is the last-defined matching rule). Under behavior-class precedence,
    // decide() must return the deny. The args pattern uses zcode's unanchored
    // glob (see argsMatch); `curl*` floats against the serialized JSON args.
    try store.addRule(.deny, .global, "Bash", "curl*", "rules.tsv", 1, "test");
    try store.addRule(.allow, .global, "Bash", "*", "rules.tsv", 2, "test");

    const curl_args = "{\"command\":\"curl evil.com\"}";

    // decide() applies deny-wins precedence: deny.
    const decided = store.decide("/repo", "Bash", curl_args).?;
    try testing.expectEqual(Action.deny, decided.action);

    // match() still reports the last-defined matching rule for debugging: allow.
    const last = store.match("/repo", "Bash", curl_args).?;
    try testing.expectEqual(Action.allow, last.rule.action);
}

test "decide: deny still wins when defined after the allow" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.allow, .global, "Bash", "*", "rules.tsv", 1, "test");
    try store.addRule(.deny, .global, "Bash", "curl*", "rules.tsv", 2, "test");

    const decided = store.decide("/repo", "Bash", "{\"command\":\"curl evil.com\"}").?;
    try testing.expectEqual(Action.deny, decided.action);
}

test "decide: ask wins over allow (behavior class 1b before 2b)" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.ask, .global, "Bash", "", "rules.tsv", 1, "test");
    try store.addRule(.allow, .global, "Bash", "ls*", "rules.tsv", 2, "test");

    const decided = store.decide("/repo", "Bash", "{\"command\":\"ls -la\"}").?;
    try testing.expectEqual(Action.ask, decided.action);
}

test "decide: pure-allow store returns allow" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.allow, .global, "Bash", "*", "rules.tsv", 1, "test");
    const decided = store.decide("/repo", "Bash", "{\"command\":\"ls\"}").?;
    try testing.expectEqual(Action.allow, decided.action);
}

test "decide: no matching rule returns null" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.deny, .global, "Read", "", "rules.tsv", 1, "test");
    try testing.expect(store.decide("/repo", "Bash", "{}") == null);
}

test "decide: deny respects workspace scope" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.allow, .global, "Bash", "*", "rules.tsv", 1, "test");
    try store.addRule(.deny, .{ .workspace = "/repo" }, "Bash", "*", "rules.tsv", 2, "test");

    // Inside the workspace, the scoped deny wins.
    try testing.expectEqual(Action.deny, store.decide("/repo/src", "Bash", "{}").?.action);
    // Outside the workspace, the scoped deny does not apply -> global allow.
    try testing.expectEqual(Action.allow, store.decide("/other", "Bash", "{}").?.action);
}

test "args pattern with star uses glob, plain stays substring" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    // glob now matches inside the serialized JSON tool args (unanchored), so a
    // CC-style command pattern fires against the real {"command":"..."} input.
    try store.addRule(.allow, .global, "Bash", "git commit*", "rules.tsv", 1, "test");
    try testing.expect(store.match("/repo", "Bash", "{\"command\":\"git commit -m hi\"}") != null);
    try testing.expect(store.match("/repo", "Bash", "{\"command\":\"git push --force\"}") == null);
    // bare command strings still work too
    try testing.expect(store.match("/repo", "Bash", "git commit -m hi") != null);

    // plain pattern keeps substring containment (matches anywhere in args)
    var store2 = Store.init(testing.allocator);
    defer store2.deinit();
    try store2.addRule(.deny, .global, "Bash", "rm -rf", "rules.tsv", 1, "test");
    try testing.expect(store2.match("/repo", "Bash", "sudo rm -rf /tmp") != null);
}

test "toolMatches MCP server-level rule matches all tools from that server" {
    // zcode uses the canonical `mcp__server__tool` scheme, not `mcp::`.
    // A server-level rule (`mcp__kali`, no tool component) matches every tool
    // from that server.
    try testing.expect(toolMatches("mcp__kali", "mcp__kali__nmap_scan"));
    try testing.expect(toolMatches("mcp__kali", "mcp__kali__sqlmap_scan"));

    // ...but not tools from a different server.
    try testing.expect(!toolMatches("mcp__kali", "mcp__miro__create-board"));

    // The explicit `*`-tool glob form behaves the same.
    try testing.expect(toolMatches("mcp__kali__*", "mcp__kali__nmap_scan"));
    try testing.expect(!toolMatches("mcp__kali__*", "mcp__miro__nmap_scan"));

    // An exact MCP tool rule matches only that exact tool.
    try testing.expect(toolMatches("mcp__kali__nmap_scan", "mcp__kali__nmap_scan"));
    try testing.expect(!toolMatches("mcp__kali__nmap_scan", "mcp__kali__sqlmap_scan"));

    // A non-MCP rule does NOT match an MCP tool (guarded by both-parse-as-MCP).
    try testing.expect(!toolMatches("Bash", "mcp__kali__nmap_scan"));
    // And the universal `*` still matches everything, MCP included.
    try testing.expect(toolMatches("*", "mcp__kali__nmap_scan"));
}

test "Store.match honors MCP server-level rules" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.allow, .global, "mcp__kali", "", "rules.tsv", 1, "test");
    try testing.expect(store.match("/repo", "mcp__kali__nmap_scan", "{}") != null);
    try testing.expect(store.match("/repo", "mcp__kali__sqlmap_scan", "{}") != null);
    try testing.expect(store.match("/repo", "mcp__miro__create-board", "{}") == null);
}

test "workspace scope matches descendants only" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.ask, .{ .workspace = "/repo" }, "*", "", "rules.tsv", 1, "test");

    try testing.expect(store.match("/repo", "Read", "{}") != null);
    try testing.expect(store.match("/repo/src", "Read", "{}") != null);
    try testing.expect(store.match("/repo-other", "Read", "{}") == null);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "loadFromSettingsJson loads allow and deny arrays from project settings" {
    const test_helpers = @import("test_helpers.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".claude");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/settings.json",
        .data = "{\"permissions\":{\"deny\":[\"Bash(rm -rf:*)\"],\"allow\":[\"Read\"]}}",
    });

    const cwd = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    try store.loadFromSettingsJson(testing.allocator, cwd, null);

    var found_deny = false;
    var found_allow = false;
    for (store.rules.items) |rule| {
        if (rule.action == .deny and std.mem.eql(u8, rule.tool, "Bash")) {
            try testing.expectEqualStrings("rm -rf:*", rule.args_contains);
            found_deny = true;
        }
        if (rule.action == .allow and std.mem.eql(u8, rule.tool, "Read")) {
            try testing.expectEqualStrings("", rule.args_contains);
            found_allow = true;
        }
    }
    try testing.expect(found_deny);
    try testing.expect(found_allow);

    // Project arrays are workspace-scoped to cwd.
    try testing.expect(store.match(cwd, "Read", "{}") != null);
}

test "loadFromSettingsJson MCP rule string loads as a single tool with empty args" {
    const test_helpers = @import("test_helpers.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".claude");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/settings.json",
        .data = "{\"permissions\":{\"allow\":[\"mcp__github__create_issue\"]}}",
    });

    const cwd = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    try store.loadFromSettingsJson(testing.allocator, cwd, null);

    try testing.expectEqual(@as(usize, 1), store.rules.items.len);
    const rule = store.rules.items[0];
    try testing.expectEqual(Action.allow, rule.action);
    try testing.expectEqualStrings("mcp__github__create_issue", rule.tool);
    try testing.expectEqualStrings("", rule.args_contains);
}

test "allowManagedPermissionRulesOnly drops non-policy rules" {
    const test_helpers = @import("test_helpers.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Point HOME at the tmp dir so the policy source resolves to
    // {tmp}/.zcode/policy/settings.json, and clear XDG_CONFIG_HOME so the
    // legacy ~/.zcode path is used. Restore on exit.
    const prev_home = env_mod.getOwned(testing.allocator, "HOME") catch null;
    defer if (prev_home) |h| {
        var hz: [std.fs.max_path_bytes:0]u8 = undefined;
        if (h.len < hz.len) {
            @memcpy(hz[0..h.len], h);
            hz[h.len] = 0;
            _ = setenv("HOME", &hz, 1);
        }
        testing.allocator.free(h);
    };
    const prev_xdg = env_mod.getOwned(testing.allocator, "XDG_CONFIG_HOME") catch null;
    defer if (prev_xdg) |x| {
        var xz: [std.fs.max_path_bytes:0]u8 = undefined;
        if (x.len < xz.len) {
            @memcpy(xz[0..x.len], x);
            xz[x.len] = 0;
            _ = setenv("XDG_CONFIG_HOME", &xz, 1);
        }
        testing.allocator.free(x);
    } else {
        _ = unsetenv("XDG_CONFIG_HOME");
    };

    {
        var home_z: [std.fs.max_path_bytes:0]u8 = undefined;
        try testing.expect(cwd.len < home_z.len);
        @memcpy(home_z[0..cwd.len], cwd);
        home_z[cwd.len] = 0;
        _ = setenv("HOME", &home_z, 1);
    }
    _ = unsetenv("XDG_CONFIG_HOME");

    // Policy settings turn on managed-only and add an allow rule.
    try tmp.dir.createDirPath(rt.io, ".zcode/policy");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/policy/settings.json",
        .data = "{\"allowManagedPermissionRulesOnly\":true,\"permissions\":{\"allow\":[\"PolicyTool\"]}}",
    });

    // Project settings add a rule that must NOT survive the managed-only gate.
    try tmp.dir.createDirPath(rt.io, ".claude");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/settings.json",
        .data = "{\"permissions\":{\"allow\":[\"ProjectTool\"]}}",
    });

    var store = Store.init(testing.allocator);
    defer store.deinit();
    try store.loadFromSettingsJson(testing.allocator, cwd, null);

    var has_policy = false;
    var has_project = false;
    for (store.rules.items) |rule| {
        if (std.mem.eql(u8, rule.tool, "PolicyTool")) has_policy = true;
        if (std.mem.eql(u8, rule.tool, "ProjectTool")) has_project = true;
    }
    try testing.expect(has_policy);
    try testing.expect(!has_project);
}

test "isAgentDenied: global deny Agent(Explore) blocks Explore only" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.deny, .global, "Agent", "Explore", "rules.tsv", 1, "test");

    try testing.expect(store.isAgentDenied("/repo", "Explore"));
    // A different agent type is not denied.
    try testing.expect(!store.isAgentDenied("/repo", "Plan"));
    // Exact match only: a prefix/substring of the denied type does not match.
    try testing.expect(!store.isAgentDenied("/repo", "Expl"));
    try testing.expect(!store.isAgentDenied("/repo", "Explorer"));
}

test "isAgentDenied: workspace-scoped deny only applies inside the workspace" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.deny, .{ .workspace = "/repo" }, "Agent", "Explore", "rules.tsv", 1, "test");

    // Inside the workspace -> denied.
    try testing.expect(store.isAgentDenied("/repo", "Explore"));
    try testing.expect(store.isAgentDenied("/repo/src", "Explore"));
    // Outside the workspace -> not denied.
    try testing.expect(!store.isAgentDenied("/other", "Explore"));
}

test "isAgentDenied: only deny rules count, and only the Agent tool" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    // An allow/ask Agent rule must NOT deny.
    try store.addRule(.allow, .global, "Agent", "Explore", "rules.tsv", 1, "test");
    try store.addRule(.ask, .global, "Agent", "Plan", "rules.tsv", 2, "test");
    // A deny rule on a different tool with the same content must NOT match.
    try store.addRule(.deny, .global, "Bash", "Explore", "rules.tsv", 3, "test");

    try testing.expect(!store.isAgentDenied("/repo", "Explore"));
    try testing.expect(!store.isAgentDenied("/repo", "Plan"));
}

test "deniedAgentTypes: collects content-keyed Agent deny rules, skips tool-wide" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.deny, .global, "Agent", "Explore", "rules.tsv", 1, "test");
    try store.addRule(.deny, .global, "Agent", "Plan", "rules.tsv", 2, "test");
    // Tool-wide Agent deny (empty content) must be skipped -- not an identity.
    try store.addRule(.deny, .global, "Agent", "", "rules.tsv", 3, "test");
    // Non-deny / non-Agent rules must be skipped.
    try store.addRule(.allow, .global, "Agent", "Review", "rules.tsv", 4, "test");
    try store.addRule(.deny, .global, "Bash", "rm", "rules.tsv", 5, "test");

    const Collector = struct {
        found_explore: bool = false,
        found_plan: bool = false,
        count: usize = 0,
        fn cb(self: *@This(), agent_type: []const u8) void {
            self.count += 1;
            if (std.mem.eql(u8, agent_type, "Explore")) self.found_explore = true;
            if (std.mem.eql(u8, agent_type, "Plan")) self.found_plan = true;
        }
    };
    var collector = Collector{};
    store.deniedAgentTypes("/repo", &collector, Collector.cb);

    try testing.expect(collector.found_explore);
    try testing.expect(collector.found_plan);
    try testing.expectEqual(@as(usize, 2), collector.count);
}

test "permission rules round trip through file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(dir_path);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "rules.tsv" });
    defer testing.allocator.free(path);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    try store.addRule(.allow, .global, "Read", "", path, 0, "user");
    try store.addRule(.deny, .{ .workspace = "/tmp/work" }, "Bash", "curl", path, 0, "user");
    try store.saveToFile(path);

    var loaded = Store.init(testing.allocator);
    defer loaded.deinit();
    try testing.expect(try loaded.loadFromFile(path));
    try testing.expectEqual(@as(usize, 2), loaded.rules.items.len);
    try testing.expectEqualStrings(path, loaded.rules.items[0].source_path);
    try testing.expectEqual(Action.deny, loaded.match("/tmp/work/app", "Bash", "curl https://example.com").?.rule.action);
}

test "loadFromFile salvages a malformed middle rule and keeps the valid ones" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(dir_path);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "rules.tsv" });
    defer testing.allocator.free(path);

    // Two valid rules in saveToFile's tab-separated format, with a malformed
    // middle line (only three fields -> bad field count). The bad line must be
    // skipped, the two valid rules must load.
    const body =
        "allow\tglobal\tRead\t\tuser\n" ++
        "deny\tglobal\tBash\n" ++
        "deny\tworkspace:/tmp/work\tBash\tcurl\tuser\n";
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "rules.tsv", .data = body });

    var store = Store.init(testing.allocator);
    defer store.deinit();
    try testing.expect(try store.loadFromFile(path));

    try testing.expectEqual(@as(usize, 2), store.rules.items.len);

    // The two valid rules are present; the malformed Bash deny is absent.
    var saw_read = false;
    var saw_curl_deny = false;
    for (store.rules.items) |rule| {
        if (rule.action == .allow and std.mem.eql(u8, rule.tool, "Read")) saw_read = true;
        if (rule.action == .deny and std.mem.eql(u8, rule.tool, "Bash") and std.mem.eql(u8, rule.args_contains, "curl")) saw_curl_deny = true;
    }
    try testing.expect(saw_read);
    try testing.expect(saw_curl_deny);
}

test "loadFromFile of an all-invalid file loads to an empty store without error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(dir_path);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "rules.tsv" });
    defer testing.allocator.free(path);

    // Every non-comment line is malformed: bad action, bad scope, bad field
    // count. None should load; the file itself must still load (return true)
    // without an error.
    const body =
        "# zcode permission rules v1\n" ++
        "bogus\tglobal\tRead\t\tuser\n" ++
        "allow\tnotascope\tRead\t\tuser\n" ++
        "allow\tglobal\tRead\n";
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "rules.tsv", .data = body });

    var store = Store.init(testing.allocator);
    defer store.deinit();
    try testing.expect(try store.loadFromFile(path));
    try testing.expectEqual(@as(usize, 0), store.rules.items.len);
}

test "replaceRules: bulk-replaces allow+source rules, leaves others untouched" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    // Three "user" allow rules, plus a deny and an allow from a different
    // source that must both survive the replace.
    try store.addRule(.allow, .global, "Read", "", "rules.tsv", 0, "user");
    try store.addRule(.allow, .global, "Bash", "ls*", "rules.tsv", 0, "user");
    try store.addRule(.allow, .global, "Bash", "git*", "rules.tsv", 0, "user");
    try store.addRule(.deny, .global, "Bash", "rm*", "rules.tsv", 0, "user");
    try store.addRule(.allow, .global, "Write", "", "rules.tsv", 0, "policy");

    const specs = [_]RuleSpec{
        .{ .tool = "Edit" },
        .{ .tool = "Bash", .args_contains = "npm*" },
    };
    try store.replaceRules(.allow, .global, "user", &specs);

    // Exactly: the two new "user" allow rules, the surviving "user" deny, and
    // the "policy" allow.
    var user_allow: usize = 0;
    var user_deny: usize = 0;
    var policy_allow: usize = 0;
    var saw_edit = false;
    var saw_npm = false;
    var saw_old_user_allow = false;
    for (store.rules.items) |rule| {
        const is_user = std.mem.eql(u8, rule.source_label, "user");
        if (is_user and rule.action == .allow) {
            user_allow += 1;
            if (std.mem.eql(u8, rule.tool, "Edit")) saw_edit = true;
            if (std.mem.eql(u8, rule.tool, "Bash") and std.mem.eql(u8, rule.args_contains, "npm*")) saw_npm = true;
            if (std.mem.eql(u8, rule.tool, "Read") or std.mem.eql(u8, rule.args_contains, "ls*") or std.mem.eql(u8, rule.args_contains, "git*")) saw_old_user_allow = true;
        }
        if (is_user and rule.action == .deny) user_deny += 1;
        if (std.mem.eql(u8, rule.source_label, "policy") and rule.action == .allow) policy_allow += 1;
    }
    try testing.expectEqual(@as(usize, 2), user_allow);
    try testing.expectEqual(@as(usize, 1), user_deny);
    try testing.expectEqual(@as(usize, 1), policy_allow);
    try testing.expect(saw_edit);
    try testing.expect(saw_npm);
    try testing.expect(!saw_old_user_allow);
}

test "replaceRules: survives a save/reload round-trip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(dir_path);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "rules.tsv" });
    defer testing.allocator.free(path);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    try store.addRule(.allow, .global, "Read", "", "rules.tsv", 0, "user");
    try store.addRule(.allow, .global, "Glob", "", "rules.tsv", 0, "user");
    try store.addRule(.allow, .global, "Grep", "", "rules.tsv", 0, "user");

    const specs = [_]RuleSpec{
        .{ .tool = "Edit" },
        .{ .tool = "Write" },
    };
    try store.replaceRules(.allow, .global, "user", &specs);
    try store.saveToFile(path);

    var loaded = Store.init(testing.allocator);
    defer loaded.deinit();
    try testing.expect(try loaded.loadFromFile(path));
    try testing.expectEqual(@as(usize, 2), loaded.rules.items.len);
    try testing.expectEqualStrings("Edit", loaded.rules.items[0].tool);
    try testing.expectEqualStrings("Write", loaded.rules.items[1].tool);
}

test "replaceRules: empty replacement set removes the whole action+source group" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.allow, .global, "Read", "", "rules.tsv", 0, "user");
    try store.addRule(.allow, .global, "Bash", "ls*", "rules.tsv", 0, "user");
    try store.addRule(.deny, .global, "Bash", "rm*", "rules.tsv", 0, "user");

    try store.replaceRules(.allow, .global, "user", &.{});

    // Both user allows gone; the deny remains.
    try testing.expectEqual(@as(usize, 1), store.rules.items.len);
    try testing.expectEqual(Action.deny, store.rules.items[0].action);
}

test "stripDangerous removes dangerous allow rules and restoreStashed reinstates them" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    // Seed: two dangerous allow rules, one safe allow, one deny.
    try store.addRule(.allow, .global, "Bash", "python:*", "rules.tsv", 1, "user");
    try store.addRule(.allow, .global, "Bash", "*", "rules.tsv", 2, "user");
    try store.addRule(.allow, .global, "Read", "", "rules.tsv", 3, "user");
    try store.addRule(.deny, .global, "Bash", "rm -rf", "rules.tsv", 4, "user");

    // Before strip: python is allowed (the broad allow rules match).
    try testing.expectEqual(Action.allow, store.decide("/repo", "Bash", "{\"command\":\"python -c 'x'\"}").?.action);

    const stash = try store.stripDangerous(testing.allocator);
    // The two dangerous allow rules are gone; the stash holds them.
    try testing.expectEqual(@as(usize, 2), stash.len);
    try testing.expectEqual(@as(usize, 2), store.rules.items.len);

    // The safe allow and the deny remain.
    var saw_read = false;
    var saw_deny = false;
    for (store.rules.items) |rule| {
        if (rule.action == .allow and std.mem.eql(u8, rule.tool, "Read")) saw_read = true;
        if (rule.action == .deny and std.mem.eql(u8, rule.tool, "Bash")) saw_deny = true;
    }
    try testing.expect(saw_read);
    try testing.expect(saw_deny);

    // After strip: a python bash call is no longer auto-allowed (no allow rule
    // matches), and the deny still applies to rm -rf. The safe allow Read is
    // unaffected and still allows a Read.
    try testing.expect(store.decide("/repo", "Bash", "{\"command\":\"python -c 'x'\"}") == null);
    try testing.expectEqual(Action.deny, store.decide("/repo", "Bash", "{\"command\":\"rm -rf /\"}").?.action);
    try testing.expectEqual(Action.allow, store.decide("/repo", "Read", "{}").?.action);

    // Restore: the store matches its original rule set.
    try store.restoreStashed(stash);
    try testing.expectEqual(@as(usize, 4), store.rules.items.len);
    try testing.expectEqual(Action.allow, store.decide("/repo", "Bash", "{\"command\":\"python -c 'x'\"}").?.action);
    try testing.expectEqual(Action.deny, store.decide("/repo", "Bash", "{\"command\":\"rm -rf /\"}").?.action);
    try testing.expectEqual(Action.allow, store.decide("/repo", "Read", "{}").?.action);
}

test "restoreStashed with an empty stash is a no-op" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.allow, .global, "Read", "", "rules.tsv", 1, "user");

    // No dangerous rules to strip -> empty stash. A first restore re-adds
    // nothing; a second restore of an empty stash is likewise a no-op
    // (mirrors the reference clearing the stash so a second exit does nothing).
    const stash = try store.stripDangerous(testing.allocator);
    try testing.expectEqual(@as(usize, 0), stash.len);
    try store.restoreStashed(stash);
    try testing.expectEqual(@as(usize, 1), store.rules.items.len);

    const empty: []Rule = &.{};
    const empty_owned = try testing.allocator.dupe(Rule, empty);
    try store.restoreStashed(empty_owned);
    try testing.expectEqual(@as(usize, 1), store.rules.items.len);
}

test "skillContentMatches: exact, prefix name:*, glob, tool-wide" {
    try testing.expect(skillContentMatches("", "anything")); // tool-wide
    try testing.expect(skillContentMatches("secret", "secret")); // exact
    try testing.expect(!skillContentMatches("secret", "secretive")); // exact, not prefix
    // name:* prefix form: matches names starting with the prefix.
    try testing.expect(skillContentMatches("foo:*", "foo"));
    try testing.expect(skillContentMatches("foo:*", "foo-bar"));
    try testing.expect(skillContentMatches("foo:*", "foobar"));
    try testing.expect(!skillContentMatches("foo:*", "barfoo"));
    // raw glob form.
    try testing.expect(skillContentMatches("dep*", "deploy"));
    try testing.expect(!skillContentMatches("dep*", "build"));
}

test "decideSkill: deny wins; name:* prefix allow; tool scope; benign miss" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    // A name:* allow plus an exact deny for the same skill; deny must win.
    try store.addRule(.allow, .global, "Skill", "foo:*", "rules.tsv", 1, "user");
    try store.addRule(.deny, .global, "Skill", "foo-bar", "rules.tsv", 2, "user");

    // foo-bar matches both the allow (prefix) and the deny (exact); deny-wins.
    {
        const d = store.decideSkill("/repo", "foo-bar").?;
        try testing.expectEqual(Action.deny, d.action);
    }
    // foo-baz matches only the prefix allow.
    {
        const d = store.decideSkill("/repo", "foo-baz").?;
        try testing.expectEqual(Action.allow, d.action);
    }
    // A skill name no rule mentions -> no decision.
    try testing.expect(store.decideSkill("/repo", "unrelated") == null);

    // A non-Skill rule (Bash) must never match a Skill decision.
    var store2 = Store.init(testing.allocator);
    defer store2.deinit();
    try store2.addRule(.deny, .global, "Bash", "foo", "rules.tsv", 1, "user");
    try testing.expect(store2.decideSkill("/repo", "foo") == null);
}
