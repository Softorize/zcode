const std = @import("std");
const std_io = @import("../core/std_io.zig");
const repl_markdown = @import("repl_markdown.zig");
const removed_commands = @import("../core/removed_commands.zig");
const commands_mod = @import("../core/commands.zig");
const skills_mod = @import("../core/skills.zig");
const display_safe = @import("../core/display_safe.zig");
const rt = @import("zcode_runtime");

const ANSI_RESET = repl_markdown.ANSI_RESET;
const ANSI_DIM = repl_markdown.ANSI_DIM;
const ANSI_BOLD = repl_markdown.ANSI_BOLD;
const ANSI_BRAND_ACCENT = repl_markdown.ANSI_BRAND_ACCENT;
const ANSI_BRAND_ACCENT_BOLD = repl_markdown.ANSI_BRAND_ACCENT_BOLD;
const ANSI_BRAND_ACCENT_DIM = repl_markdown.ANSI_BRAND_ACCENT_DIM;

/// One command shown on the /help screen.
pub const HelpEntry = struct {
    usage: []const u8,
    desc: []const u8,
};

/// A titled section of related commands. Groups exist so users can scan
/// ~90 commands by category instead of reading a flat wall of text.
pub const HelpGroup = struct {
    title: []const u8,
    entries: []const HelpEntry,
};

// Column width for the command column in rendered output. Most entries
// fit within 32 cols; longer ones overflow cleanly into the description.
const USAGE_COLUMN: usize = 34;

const getting_started = [_]HelpEntry{
    .{ .usage = "/help", .desc = "Show this screen" },
    .{ .usage = "/help keys", .desc = "Show the fullscreen keyboard and leader-key reference" },
    .{ .usage = "/help commands", .desc = "Show the full slash-command catalog" },
    .{ .usage = "/exit, /quit", .desc = "Exit the session" },
    .{ .usage = "/version, /v", .desc = "Print the zcode build version" },
    .{ .usage = "/whoami", .desc = "One-line provider/model/agent/version" },
    .{ .usage = "/pwd", .desc = "Show the current shell working directory" },
    .{ .usage = "/cd [path]", .desc = "Change shell cwd (default: ~). Subsequent tools run there." },
    .{ .usage = "/! <cmd>", .desc = "Run an interactive terminal command attached to your terminal" },
    .{ .usage = "/init", .desc = "Drop a starter ZCODE.md skeleton in the current cwd" },
    .{ .usage = "/config [key]", .desc = "Show config; /config set <key> <value> to change" },
    .{ .usage = "/features", .desc = "Show feature gates and kill switches" },
    .{ .usage = "/context", .desc = "Show what is consuming the context window" },
    .{ .usage = "/fast [on|off]", .desc = "Toggle between fast (sonnet/flash) and quality (opus/pro) models" },
    .{ .usage = "/brief [on|off]", .desc = "Toggle compact brief view for the fullscreen transcript" },
    .{ .usage = "/color <name|default>", .desc = "Set the session prompt-bar accent color (or on|off for ANSI)" },
    .{ .usage = "/status", .desc = "Show runtime config (provider, model, policy)" },
    .{ .usage = "/session", .desc = "Show session id and turn count" },
    .{ .usage = "/doctor", .desc = "Run diagnostics on the zcode installation" },
    .{ .usage = "/errors", .desc = "Show recent errors recorded in the in-memory ring (for bug reports)" },
    .{ .usage = "/clear", .desc = "Clear the current conversation" },
    .{ .usage = "/reset", .desc = "Reset the session to a fresh state" },
    .{ .usage = "/usage", .desc = "Show token and budget usage summary" },
    .{ .usage = "/cost", .desc = "Show session cost estimation" },
    .{ .usage = "/compact", .desc = "Force a conversation compaction snapshot" },
    .{ .usage = "/copy [N]", .desc = "Copy the last assistant response (or the Nth-latest) to the clipboard" },
    .{ .usage = "/transcript", .desc = "Open the transcript pager with search, export, and scrollback dump" },
    .{ .usage = "/todos", .desc = "Show the current open-task checklist" },
    .{ .usage = "/tasks, /bashes", .desc = "List and manage tracked background tasks" },
    .{ .usage = "/teams", .desc = "Show local team metadata and recent team message status" },
    .{ .usage = "/bridge", .desc = "Show browser and MCP bridge status for this local runtime" },
    .{ .usage = "/files", .desc = "List files the model has Read or Edited this session" },
};

const input_and_keys = [_]HelpEntry{
    .{ .usage = "? on empty prompt", .desc = "Open the shortcuts panel with palette/model/density/runtime controls" },
    .{ .usage = "Ctrl+X H", .desc = "Open the command palette (fullscreen)" },
    .{ .usage = "Ctrl+X A", .desc = "Open the runtime and automation panel (fullscreen)" },
    .{ .usage = "Ctrl+X S", .desc = "Open the session switcher (fullscreen)" },
    .{ .usage = "Ctrl+X M / F / G / T / P / B", .desc = "Leader actions: model, files, search, tasks, theme, density" },
    .{ .usage = "Tab Tab", .desc = "Toggle clean/full density when no picker or completion is active" },
    .{ .usage = "Shift+Enter", .desc = "Insert newline (multiline compose)" },
    .{ .usage = "Shift+Tab", .desc = "Cycle mode: execution / planning / brainstorm" },
    .{ .usage = "Tab", .desc = "Autocomplete slash commands and @file references (fullscreen)" },
    .{ .usage = "Ctrl+R", .desc = "Search previous prompts for the current workspace (fullscreen)" },
    .{ .usage = "Ctrl+Shift+F", .desc = "Search the workspace with file/line preview (fullscreen)" },
    .{ .usage = "Ctrl+L", .desc = "Force a clean redraw of the fullscreen UI" },
    .{ .usage = "Ctrl+E", .desc = "Open the transcript pager; inside it Ctrl+E toggles compact/expanded view" },
    .{ .usage = "Ctrl+O", .desc = "Collapse or restore the transcript pane (fullscreen)" },
    .{ .usage = "Ctrl+T", .desc = "Open the live todo checklist overlay (fullscreen)" },
    .{ .usage = "Ctrl+Shift+B", .desc = "Toggle brief mode (dense transcript with collapsed assistant replies)" },
    .{ .usage = "Shift+Up", .desc = "Open message actions for recent transcript items (fullscreen)" },
    .{ .usage = "Ctrl+V", .desc = "Paste an image from the clipboard into the prompt as a temp PNG path" },
    .{ .usage = "/! command", .desc = "Launch vim/less/ssh/top-style commands outside the transcript UI" },
    .{ .usage = "Esc / i / a / dd / yy / p", .desc = "Core vim insert/normal editing when /vim is enabled" },
    .{ .usage = "Ctrl+_ / Ctrl+Shift+-", .desc = "Undo the last prompt edit (fullscreen)" },
    .{ .usage = "Ctrl+G / Ctrl+X Ctrl+E", .desc = "Edit the current prompt in $VISUAL / $EDITOR" },
    .{ .usage = "Ctrl+X Ctrl+K", .desc = "Press twice to stop tracked background tasks" },
    .{ .usage = "Ctrl+S", .desc = "Stash the current prompt, or restore the stashed draft" },
    .{ .usage = "Ctrl+P / Ctrl+Shift+P", .desc = "Quick open files with preview (fullscreen)" },
    .{ .usage = "Alt+P", .desc = "Open the model picker (fullscreen)" },
    .{ .usage = "Alt+O", .desc = "Toggle fast mode (fullscreen)" },
    .{ .usage = "Alt+T", .desc = "Open the reasoning-summary dialog (fullscreen)" },
    .{ .usage = "Ctrl-U / Cmd-Backspace", .desc = "Clear the current input line" },
    .{ .usage = "Ctrl-W / Alt-Backspace", .desc = "Delete the previous word" },
    .{ .usage = "Paste / drag-drop", .desc = "Paste text or image paths; large text pastes auto-store to temp files" },
};

const modes_and_plans = [_]HelpEntry{
    .{ .usage = "/mode [name]", .desc = "Show or set mode (execution|planning|brainstorm|review)" },
    .{ .usage = "/density [full|clean]", .desc = "Show or set fullscreen UI density" },
    .{ .usage = "/brief", .desc = "Toggle brief mode for the fullscreen transcript" },
    .{ .usage = "/vim", .desc = "Toggle vim editing for the fullscreen prompt" },
    .{ .usage = "/plan <action>", .desc = "Plan actions: approve | discuss | cancel" },
    .{ .usage = "/approve-plan", .desc = "Alias for /plan approve" },
    .{ .usage = "/yolo", .desc = "Open the auto-mode dialog (fullscreen) or toggle YOLO inline" },
    .{ .usage = "/effort [level]", .desc = "Show or set reasoning effort (auto|low|medium|high|max)" },
    .{ .usage = "/format json <schema>", .desc = "Enforce a JSON schema on the next response" },
    .{ .usage = "/format clear", .desc = "Clear any pending response schema" },
};

const models_and_providers = [_]HelpEntry{
    .{ .usage = "/models", .desc = "List models for the active provider" },
    .{ .usage = "/model", .desc = "Open model picker (fullscreen)" },
    .{ .usage = "/model current", .desc = "Show active provider / model" },
    .{ .usage = "/model <id>", .desc = "Switch active model (or provider/model)" },
    .{ .usage = "/fast", .desc = "Toggle fast mode for the current model" },
    .{ .usage = "/memory", .desc = "Show or edit persistent memory entries" },
    .{ .usage = "/theme", .desc = "Open the theme picker (fullscreen) or list themes inline" },
    .{ .usage = "/theme current", .desc = "Show the current theme setting and resolved palette" },
    .{ .usage = "/theme syntax on|off", .desc = "Persist code-block syntax highlighting on or off" },
    .{ .usage = "/preprocessor", .desc = "Show session preprocessor settings" },
    .{ .usage = "/preprocessor on|off", .desc = "Enable or disable the preprocessor" },
    .{ .usage = "/preprocessor list [prov]", .desc = "List preprocessor models" },
    .{ .usage = "/preprocessor <id>", .desc = "Switch preprocessor model" },
    .{ .usage = "/lang", .desc = "Show the preferred response language" },
    .{ .usage = "/lang <language>", .desc = "Set the preferred response language (e.g. Spanish, ja)" },
    .{ .usage = "/lang clear", .desc = "Clear the preferred language (default to English)" },
};

const sessions = [_]HelpEntry{
    .{ .usage = "/new", .desc = "Start a new session" },
    .{ .usage = "/resume [id]", .desc = "Resume a session by id, or open the interactive picker with no id (alias /continue)" },
    .{ .usage = "/rename <label>", .desc = "Rename the current session" },
    .{ .usage = "/export [path]", .desc = "Export the current session bundle" },
    .{ .usage = "/rewind [n]", .desc = "Open the rewind selector in fullscreen, or rewind the last n assistant turns" },
    .{ .usage = "/session checkpoint [name]", .desc = "Save a workspace-aware checkpoint" },
    .{ .usage = "/session checkpoints", .desc = "List checkpoints for the current session" },
    .{ .usage = "/session restore [name]", .desc = "Restore a checkpoint and switch sessions" },
    .{ .usage = "/session fork [name]", .desc = "Fork the current session" },
    .{ .usage = "/branch [name]", .desc = "Fork the current conversation at this point (alias /fork)" },
};

const agents_and_skills = [_]HelpEntry{
    .{ .usage = "/agents", .desc = "List available agents" },
    .{ .usage = "/agent current", .desc = "Show the active agent" },
    .{ .usage = "/agent <name>", .desc = "Activate an agent for this session" },
    .{ .usage = "/agent none", .desc = "Clear the active agent" },
    .{ .usage = "/skills", .desc = "List available skills" },
    .{ .usage = "/skill <name> ...", .desc = "Show or run a skill" },
    .{ .usage = "/hooks", .desc = "List installed hooks" },
};

const plugins_and_commands = [_]HelpEntry{
    .{ .usage = "/plugins", .desc = "List installed plugins" },
    .{ .usage = "/plugin <name>", .desc = "Show plugin details" },
    .{ .usage = "/plugin install <name>", .desc = "Install a marketplace plugin" },
    .{ .usage = "/plugin uninstall <name>", .desc = "Remove an installed plugin" },
    .{ .usage = "/plugin update <name>", .desc = "Reinstall a plugin from its catalog" },
    .{ .usage = "/commands", .desc = "List reusable commands" },
    .{ .usage = "/command <name> ...", .desc = "Show or run a reusable command" },
    .{ .usage = "/command install <name>", .desc = "Install a marketplace command" },
    .{ .usage = "/command uninstall <name>", .desc = "Remove an installed command" },
    .{ .usage = "/command update <name>", .desc = "Reinstall a command from its catalog" },
};

const marketplace = [_]HelpEntry{
    .{ .usage = "/marketplace sources", .desc = "List registered marketplace catalogs" },
    .{ .usage = "/marketplace add <name> <url> [sha256]", .desc = "Add and refresh a source" },
    .{ .usage = "/marketplace remove <name>", .desc = "Remove a marketplace source" },
    .{ .usage = "/marketplace refresh [name]", .desc = "Refresh marketplace caches" },
};

const mcp_commands = [_]HelpEntry{
    .{ .usage = "/mcp", .desc = "List MCP servers" },
    .{ .usage = "/mcp tools <server>", .desc = "List tools discovered from an MCP server" },
    .{ .usage = "/mcp resources <server>", .desc = "List resources from an MCP server" },
    .{ .usage = "/mcp templates <server>", .desc = "List resource templates" },
    .{ .usage = "/mcp read <server> <uri>", .desc = "Read an MCP resource" },
    .{ .usage = "/mcp prompts <server>", .desc = "List prompts from an MCP server" },
    .{ .usage = "/mcp prompt <server> <name>", .desc = "Get an MCP prompt (optional JSON args)" },
    .{ .usage = "/mcp subscribe <server> <uri>", .desc = "Subscribe to resource updates" },
    .{ .usage = "/mcp notifications [server]", .desc = "Show queued MCP notifications" },
    .{ .usage = "/mcp auth login <server>", .desc = "Set MCP auth (token or oauth:url)" },
    .{ .usage = "/mcp auth logout <server>", .desc = "Remove MCP auth" },
};

const git_and_review = [_]HelpEntry{
    .{ .usage = "/review [target]", .desc = "Review working changes, commit, or branch" },
    .{ .usage = "/commit [context]", .desc = "Stage changes and create a git commit" },
    .{ .usage = "/pr [context]", .desc = "Push branch and open a pull request via gh" },
    .{ .usage = "/pr-comments [target]", .desc = "Fetch PR review comments" },
    .{ .usage = "/pr-status", .desc = "Show PR review state (approved/pending/changes_requested)" },
    .{ .usage = "/diff [target]", .desc = "Show a unified diff for working changes" },
    .{ .usage = "/open, /quick-open", .desc = "Open the quick-open file picker (fullscreen)" },
    .{ .usage = "/security-review", .desc = "Run the security review flow" },
    .{ .usage = "/worktree [path]", .desc = "Show or switch git worktree context" },
};

const trust_and_policy = [_]HelpEntry{
    .{ .usage = "/trust", .desc = "Show repo trust status" },
    .{ .usage = "/trust hooks", .desc = "Show hook fingerprint trust state" },
    .{ .usage = "/trust hook allow <path>", .desc = "Trust a workspace hook fingerprint" },
    .{ .usage = "/trust hook revoke <path>", .desc = "Revoke a trusted hook fingerprint" },
    .{ .usage = "/trust marketplace", .desc = "Show marketplace allow/block policy" },
    .{ .usage = "/trust marketplace allow <prefix>", .desc = "Allow a remote source prefix" },
    .{ .usage = "/trust marketplace block <prefix>", .desc = "Block a remote source prefix" },
    .{ .usage = "/policy", .desc = "Print the effective policy" },
    .{ .usage = "/permissions", .desc = "Show and manage approval permission rules" },
    .{ .usage = "/sandbox", .desc = "Show the current sandbox configuration" },
    .{ .usage = "/sandbox-toggle", .desc = "Cycle through sandbox profiles" },
};

const workspace_and_setup = [_]HelpEntry{
    .{ .usage = "/init", .desc = "Initialize zcode in the current workspace" },
    .{ .usage = "/onboarding", .desc = "Run the first-launch onboarding flow" },
    .{ .usage = "/add-dir <path>", .desc = "Add a directory to the workspace scope" },
    .{ .usage = "/env", .desc = "Show detected environment info (platform, shell, cwd, ...)" },
    .{ .usage = "/env list", .desc = "List session env vars applied to spawned shell commands" },
    .{ .usage = "/env set NAME=VAL", .desc = "Set a session env var for subprocess children" },
    .{ .usage = "/env unset NAME", .desc = "Drop a session env var" },
    .{ .usage = "/env clear", .desc = "Clear all session env vars" },
    .{ .usage = "/env registry", .desc = "List every environment variable zcode reads (provider keys redacted)" },
    .{ .usage = "/keybindings", .desc = "Open the context-aware keybindings file in your editor" },
    .{ .usage = "/styles, /style [name]", .desc = "Open the output style picker (fullscreen) or list/switch styles inline" },
    .{ .usage = "/reload", .desc = "Reload prompt-side keybindings from disk without restarting" },
    .{ .usage = "/reload-plugins", .desc = "Rescan and reload installed plugins" },
};

const updates_and_feedback = [_]HelpEntry{
    .{ .usage = "/upgrade", .desc = "Upgrade zcode to the latest release" },
    .{ .usage = "/update", .desc = "Alias for /upgrade" },
    .{ .usage = "/release-notes", .desc = "Show release notes for the current version" },
    .{ .usage = "/changelog", .desc = "Show the project changelog" },
    .{ .usage = "/feedback", .desc = "Send feedback to the maintainers" },
    .{ .usage = "/issue [title]", .desc = "Open a GitHub issue for the project" },
    .{ .usage = "/stickers", .desc = "Open the stickers redemption page" },
};

pub const GROUPS = [_]HelpGroup{
    .{ .title = "Getting started", .entries = &getting_started },
    .{ .title = "Input & keyboard", .entries = &input_and_keys },
    .{ .title = "Modes & planning", .entries = &modes_and_plans },
    .{ .title = "Models & providers", .entries = &models_and_providers },
    .{ .title = "Sessions", .entries = &sessions },
    .{ .title = "Agents, skills & styles", .entries = &agents_and_skills },
    .{ .title = "Plugins & commands", .entries = &plugins_and_commands },
    .{ .title = "Marketplace", .entries = &marketplace },
    .{ .title = "MCP (Model Context Protocol)", .entries = &mcp_commands },
    .{ .title = "Git & review", .entries = &git_and_review },
    .{ .title = "Trust, policy & sandbox", .entries = &trust_and_policy },
    .{ .title = "Workspace & setup", .entries = &workspace_and_setup },
    .{ .title = "Updates & feedback", .entries = &updates_and_feedback },
};

pub const HelpView = enum {
    overview,
    keys,
    commands,
};

const overview_start_work = [_]HelpEntry{
    .{ .usage = "Type a task", .desc = "Ask zcode to build, fix, review, or explain something in the current workspace" },
    .{ .usage = "? on empty prompt", .desc = "Open the shortcuts panel for the current session" },
    .{ .usage = "Ctrl+X H", .desc = "Open the command palette for all major controls" },
    .{ .usage = "Ctrl+X M", .desc = "Switch model/provider without leaving the composer" },
};

const overview_search_navigate = [_]HelpEntry{
    .{ .usage = "Ctrl+X F", .desc = "Quick-open files with preview and prompt insertion" },
    .{ .usage = "Ctrl+X G", .desc = "Search the workspace with line preview" },
    .{ .usage = "Ctrl+R", .desc = "Search previous prompts for the current workspace" },
    .{ .usage = "Ctrl+X S", .desc = "Browse and resume saved sessions" },
};

const overview_runtime_review = [_]HelpEntry{
    .{ .usage = "Ctrl+X A", .desc = "Open the runtime control panel for tasks, approvals, model state, and automation" },
    .{ .usage = "Ctrl+X T", .desc = "Open the background tasks overlay" },
    .{ .usage = "/status", .desc = "Append the full runtime state to the transcript" },
    .{ .usage = "/review [target]", .desc = "Review the current diff, commit, or branch" },
};

const overview_display_customize = [_]HelpEntry{
    .{ .usage = "Tab Tab / Ctrl+X B", .desc = "Toggle fullscreen density between full and clean" },
    .{ .usage = "Ctrl+X P", .desc = "Open the theme picker" },
    .{ .usage = "/help keys", .desc = "Show the complete keyboard and leader-key reference" },
    .{ .usage = "/help commands", .desc = "Show the full slash-command catalog" },
};

const OVERVIEW_GROUPS = [_]HelpGroup{
    .{ .title = "Start Work", .entries = &overview_start_work },
    .{ .title = "Search & navigate", .entries = &overview_search_navigate },
    .{ .title = "Runtime & review", .entries = &overview_runtime_review },
    .{ .title = "Display & customize", .entries = &overview_display_customize },
};

/// Best-effort lookup used by the fullscreen slash-command suggestion
/// overlay. We match on prefix rather than exact equality so a typed
/// prefix like `/plugin ` can still reuse the `/plugin <name>` help
/// description. When multiple entries match, prefer the shortest usage
/// string so the generic command help wins over more specific variants.
pub fn findEntryForUsagePrefix(prefix_raw: []const u8) ?HelpEntry {
    const prefix = std.mem.trimEnd(u8, prefix_raw, " \t");
    if (prefix.len == 0) return null;

    var best: ?HelpEntry = null;
    var best_usage_len: usize = std.math.maxInt(usize);

    for (GROUPS) |group| {
        for (group.entries) |entry| {
            if (removed_commands.isRemoved(entry.usage)) continue; // hide removed commands (PRD #534)
            if (!std.mem.startsWith(u8, entry.usage, prefix)) continue;
            if (entry.usage.len < best_usage_len) {
                best = entry;
                best_usage_len = entry.usage.len;
            }
        }
    }
    return best;
}

pub fn descriptionForUsagePrefix(prefix_raw: []const u8) ?[]const u8 {
    const entry = findEntryForUsagePrefix(prefix_raw) orelse return null;
    return entry.desc;
}

fn writeHelpHeader(writer: anytype, use_color: bool, title: []const u8, subtitle: []const u8) !void {
    if (use_color) {
        try writer.print("\n  {s}{s}{s}  {s}\xe2\x80\x94 {s}{s}\n", .{
            ANSI_BRAND_ACCENT_BOLD,
            title,
            ANSI_RESET,
            ANSI_DIM,
            subtitle,
            ANSI_RESET,
        });
        try writer.print("  {s}" ++ ("\xe2\x94\x80" ** 28) ++ "{s}\n", .{ ANSI_BRAND_ACCENT_DIM, ANSI_RESET });
    } else {
        try writer.print("\n{s} -- {s}\n", .{ title, subtitle });
        try writer.writeAll("  " ++ ("-" ** 28) ++ "\n");
    }
}

fn writeHelpGroups(writer: anytype, groups: []const HelpGroup, use_color: bool) !void {
    const section_bar = "\xe2\x96\x8e";
    for (groups) |group| {
        try writer.writeAll("\n");
        if (use_color) {
            try writer.print(
                "  {s}{s}{s} {s}{s}{s}\n",
                .{
                    ANSI_BRAND_ACCENT,
                    section_bar,
                    ANSI_RESET,
                    ANSI_BRAND_ACCENT_BOLD,
                    group.title,
                    ANSI_RESET,
                },
            );
        } else {
            try writer.print("  {s} {s}\n", .{ section_bar, group.title });
        }
        for (group.entries) |entry| {
            if (removed_commands.isRemoved(entry.usage)) continue; // hide removed commands (PRD #534)
            try writeHelpEntry(writer, entry, use_color);
        }
    }
}

pub fn writeOverviewScreen(writer: anytype, use_color: bool) !void {
    try writeHelpHeader(writer, use_color, "zcode help", "task-first guide");
    try writeHelpGroups(writer, OVERVIEW_GROUPS[0..], use_color);
    if (use_color) {
        try writer.print("\n  {s}Any other input runs an agent turn.{s}\n\n", .{ ANSI_DIM, ANSI_RESET });
    } else {
        try writer.writeAll("\n  Any other input runs an agent turn.\n\n");
    }
}

pub fn writeKeysScreen(writer: anytype, use_color: bool) !void {
    const key_groups = [_]HelpGroup{
        .{ .title = "Input & keyboard", .entries = &input_and_keys },
        .{ .title = "Modes & planning", .entries = &modes_and_plans },
    };
    try writeHelpHeader(writer, use_color, "zcode keys", "fullscreen shortcuts and leader actions");
    try writeHelpGroups(writer, key_groups[0..], use_color);
    if (use_color) {
        try writer.print("\n  {s}Run /help commands for the full slash-command catalog.{s}\n\n", .{ ANSI_DIM, ANSI_RESET });
    } else {
        try writer.writeAll("\n  Run /help commands for the full slash-command catalog.\n\n");
    }
}

/// Render the grouped help screen to `writer`. When `use_color` is true,
/// the title row uses the brand mint accent, group titles are bold brand,
/// command names stay default weight, and descriptions dim to secondary.
/// When false, output is pure ASCII/UTF-8 with no escape sequences so it
/// composes safely into the scrollable transcript or into pipes.
pub fn writeHelpScreen(writer: anytype, use_color: bool) !void {
    try writeHelpHeader(writer, use_color, "zcode commands", "grouped by topic");
    try writeHelpGroups(writer, GROUPS[0..], use_color);

    if (use_color) {
        try writer.print("\n  {s}Any other input runs an agent turn.{s}\n\n", .{ ANSI_DIM, ANSI_RESET });
    } else {
        try writer.writeAll("\n  Any other input runs an agent turn.\n\n");
    }
}

/// commands-06: enumerate the user-defined custom commands and skills for the
/// workspace at `cwd` and render them as extra help groups, so `/help` surfaces
/// the live registry (built-in + custom + skill), not just the static built-in
/// catalog. Disk I/O runs on the submit path only (never per keystroke). On any
/// load error the section is silently skipped so `/help` never fails because a
/// user file is malformed. A scope tag `(user)` / `(workspace)` is appended to
/// each row mirroring the reference's source annotation.
fn writeDynamicGroupHeader(writer: anytype, title: []const u8, use_color: bool) !void {
    const section_bar = "\xe2\x96\x8e";
    if (use_color) {
        try writer.print(
            "\n  {s}{s}{s} {s}{s}{s}\n",
            .{ ANSI_BRAND_ACCENT, section_bar, ANSI_RESET, ANSI_BRAND_ACCENT_BOLD, title, ANSI_RESET },
        );
    } else {
        try writer.print("\n  {s} {s}\n", .{ section_bar, title });
    }
}

/// Write a single dynamic row. `usage` is the `/<name>` form; `scope_tag` is
/// `user`/`workspace`; `desc` is the (already-sanitized) description; `hint` is
/// the argument hint (may be empty). Mirrors `writeHelpEntry`'s two-column
/// layout. The scope tag and hint fold into the description column so the row
/// stays a single TSV-free line.
fn writeDynamicRow(
    writer: anytype,
    allocator: std.mem.Allocator,
    usage: []const u8,
    scope_tag: []const u8,
    desc: []const u8,
    hint: []const u8,
    use_color: bool,
) !void {
    // Compose the description column: "(scope) desc [hint]" with empty parts
    // omitted, so a command with no description still shows its scope.
    var detail = std_io.StringBuilder.init(allocator);
    defer detail.deinit();
    try detail.writer().print("({s})", .{scope_tag});
    if (desc.len > 0) try detail.writer().print(" {s}", .{desc});
    if (hint.len > 0) try detail.writer().print(" {s}", .{hint});

    const entry = HelpEntry{ .usage = usage, .desc = detail.items() };
    try writeHelpEntry(writer, entry, use_color);
}

/// Append the "Custom commands" and "Skills" groups for `cwd`. Returns true if
/// at least one row was written. Never errors on a bad user file: load failures
/// degrade to an empty (skipped) section.
pub fn writeDynamicCommandsSection(
    writer: anytype,
    allocator: std.mem.Allocator,
    cwd: []const u8,
    use_color: bool,
) !bool {
    var wrote_any = false;

    if (commands_mod.list(allocator, cwd)) |commands| {
        defer commands_mod.freeList(allocator, commands);
        var header_written = false;
        for (commands) |command| {
            if (!command.user_invocable) continue;
            if (!header_written) {
                try writeDynamicGroupHeader(writer, "Custom commands", use_color);
                header_written = true;
                wrote_any = true;
            }
            const usage = try std.fmt.allocPrint(allocator, "/{s}", .{command.name});
            defer allocator.free(usage);
            const safe_desc = try display_safe.sanitize(allocator, command.description);
            defer allocator.free(safe_desc);
            const safe_hint = try display_safe.sanitize(allocator, command.argument_hint);
            defer allocator.free(safe_hint);
            try writeDynamicRow(
                writer,
                allocator,
                usage,
                commands_mod.scopeName(command.scope),
                safe_desc,
                safe_hint,
                use_color,
            );
        }
    } else |_| {}

    if (skills_mod.list(allocator, cwd)) |skills| {
        defer skills_mod.freeList(allocator, skills);
        var header_written = false;
        for (skills) |skill| {
            if (!skill.user_invocable) continue;
            if (!header_written) {
                try writeDynamicGroupHeader(writer, "Skills", use_color);
                header_written = true;
                wrote_any = true;
            }
            const usage = try std.fmt.allocPrint(allocator, "/{s}", .{skill.name});
            defer allocator.free(usage);
            const safe_desc = try display_safe.sanitize(allocator, skill.description);
            defer allocator.free(safe_desc);
            try writeDynamicRow(
                writer,
                allocator,
                usage,
                skills_mod.scopeName(skill.scope),
                safe_desc,
                "",
                use_color,
            );
        }
    } else |_| {}

    return wrote_any;
}

/// Build the `/help commands` plaintext PLUS the dynamic custom-command/skill
/// section for `cwd`. The caller owns the returned buffer. This is the string
/// the `/help commands` (and `/help`) text path emits so the live registry is
/// surfaced; `buildPlaintext` (static only) is retained for callers that have
/// no workspace context.
pub fn buildPlaintextWithDynamic(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try writeHelpScreen(buf.writer(), false);
    _ = try writeDynamicCommandsSection(buf.writer(), allocator, cwd, false);
    return buf.toOwnedSlice();
}

/// Render the `/help commands` screen to `writer`, including the dynamic
/// custom-command/skill section for `cwd`. Mirrors `writeHelpScreen` but with
/// the live-registry groups appended.
pub fn writeHelpScreenWithDynamic(
    writer: anytype,
    allocator: std.mem.Allocator,
    cwd: []const u8,
    use_color: bool,
) !void {
    try writeHelpScreen(writer, use_color);
    _ = try writeDynamicCommandsSection(writer, allocator, cwd, use_color);
}

fn writeHelpEntry(writer: anytype, entry: HelpEntry, use_color: bool) !void {
    if (entry.usage.len >= USAGE_COLUMN) {
        // Long usage: keep it on its own line, then description on a new
        // line indented to the column width so the two-column alignment
        // is preserved for the rest of the group.
        if (use_color) {
            try writer.print("    {s}{s}{s}\n", .{ ANSI_BOLD, entry.usage, ANSI_RESET });
            try writer.splatByteAll(' ', 4 + USAGE_COLUMN);
            try writer.print("{s}{s}{s}\n", .{ ANSI_DIM, entry.desc, ANSI_RESET });
        } else {
            try writer.print("    {s}\n", .{entry.usage});
            try writer.splatByteAll(' ', 4 + USAGE_COLUMN);
            try writer.print("{s}\n", .{entry.desc});
        }
        return;
    }

    const pad_len = USAGE_COLUMN - entry.usage.len;
    if (use_color) {
        try writer.print("    {s}{s}{s}", .{ ANSI_BOLD, entry.usage, ANSI_RESET });
        try writer.splatByteAll(' ', pad_len);
        try writer.print("{s}{s}{s}\n", .{ ANSI_DIM, entry.desc, ANSI_RESET });
    } else {
        try writer.print("    {s}", .{entry.usage});
        try writer.splatByteAll(' ', pad_len);
        try writer.print("{s}\n", .{entry.desc});
    }
}

/// Build the plain-text (no ANSI) help screen as an allocated string. The
/// caller owns the returned buffer. Used by the fullscreen transcript
/// path where escape codes would be stripped or confuse line wrapping.
pub fn buildPlaintext(allocator: std.mem.Allocator) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try writeHelpScreen(buf.writer(), false);
    return buf.toOwnedSlice();
}

pub fn buildOverviewPlaintext(allocator: std.mem.Allocator) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try writeOverviewScreen(buf.writer(), false);
    return buf.toOwnedSlice();
}

pub fn buildKeysPlaintext(allocator: std.mem.Allocator) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try writeKeysScreen(buf.writer(), false);
    return buf.toOwnedSlice();
}

const testing = std.testing;

test "help groups cover core commands" {
    const plaintext = try buildPlaintext(testing.allocator);
    defer testing.allocator.free(plaintext);

    // Spot-check a command from each major group so a future edit that
    // accidentally drops a whole section gets caught in CI.
    try testing.expect(std.mem.indexOf(u8, plaintext, "/help") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "/model current") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "/session checkpoint") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "/agents") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "/skills") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "/plugins") != null);
    // /marketplace was removed for CC parity (use /plugins); group still covered by /plugins above.
    try testing.expect(std.mem.indexOf(u8, plaintext, "/mcp tools") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "/review") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "/trust") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "/policy") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "/effort") != null);
}

test "help plaintext contains group headers" {
    const plaintext = try buildPlaintext(testing.allocator);
    defer testing.allocator.free(plaintext);

    // Plaintext prefixes each group title with a `▎` section-mark
    // bar (U+258E) so callers reading the transcript can visually
    // identify sections without relying on ANSI.
    try testing.expect(std.mem.indexOf(u8, plaintext, "\xe2\x96\x8e Getting started") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "\xe2\x96\x8e Modes & planning") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "\xe2\x96\x8e Models & providers") != null);
}

test "help overview plaintext surfaces task-first controls" {
    const plaintext = try buildOverviewPlaintext(testing.allocator);
    defer testing.allocator.free(plaintext);

    try testing.expect(std.mem.indexOf(u8, plaintext, "Start Work") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "Ctrl+X H") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "Ctrl+X S") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "/help commands") != null);
}

test "help keys plaintext includes leader and density shortcuts" {
    const plaintext = try buildKeysPlaintext(testing.allocator);
    defer testing.allocator.free(plaintext);

    try testing.expect(std.mem.indexOf(u8, plaintext, "Ctrl+X S") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "Tab Tab") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "Ctrl+X A") != null);
}

test "help plaintext does not contain ANSI escapes" {
    const plaintext = try buildPlaintext(testing.allocator);
    defer testing.allocator.free(plaintext);

    // Plaintext must be safe for transcripts and pipes.
    try testing.expect(std.mem.indexOf(u8, plaintext, "\x1b[") == null);
}

test "help colored output contains ANSI escapes" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    try writeHelpScreen(buf.writer(), true);

    try testing.expect(std.mem.indexOf(u8, buf.items(), "\x1b[") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), ANSI_BRAND_ACCENT_BOLD) != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), ANSI_DIM) != null);
}

test "help entry with long usage wraps description onto next line" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    const long_entry = HelpEntry{
        .usage = "/marketplace add <name> <url> [sha256]",
        .desc = "Add and refresh a source",
    };
    try writeHelpEntry(buf.writer(), long_entry, false);

    // The description should be on its own line after the long usage.
    const newline_count = std.mem.count(u8, buf.items(), "\n");
    try testing.expect(newline_count == 2);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "Add and refresh a source") != null);
}

// commands-06: /help enumerates the user's custom commands and skills.

test "help commands plaintext enumerates a tmp custom command" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/commands");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/commands/deploy.md",
        .data =
        \\---
        \\description: Deploy the app
        \\argument-hint: <env>
        \\---
        \\Deploy to $env
        ,
    });

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const plaintext = try buildPlaintextWithDynamic(allocator, cwd);
    defer allocator.free(plaintext);

    // The custom command name, its section header, scope tag, description, and
    // argument hint should all appear.
    try testing.expect(std.mem.indexOf(u8, plaintext, "/deploy") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "Custom commands") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "(workspace)") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "Deploy the app") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "<env>") != null);

    // The static built-in catalog must still be present (no regression).
    try testing.expect(std.mem.indexOf(u8, plaintext, "/help") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "/model current") != null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "/skills") != null);
}

test "help commands plaintext shows nothing extra when no custom commands exist" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const plaintext = try buildPlaintextWithDynamic(allocator, cwd);
    defer allocator.free(plaintext);

    // No custom commands/skills -> no dynamic headers, but the static catalog
    // is unchanged.
    try testing.expect(std.mem.indexOf(u8, plaintext, "Custom commands") == null);
    try testing.expect(std.mem.indexOf(u8, plaintext, "/model current") != null);

    // Output must remain ANSI-free (transcript/pipe safe).
    try testing.expect(std.mem.indexOf(u8, plaintext, "\x1b[") == null);
}

test "dynamic section skips non-user-invocable commands" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/commands");
    // user-invocable command -> listed.
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/commands/visible.md",
        .data =
        \\---
        \\description: A visible command
        \\---
        \\body
        ,
    });
    // disable-model-invocation does not affect user-invocability, but a command
    // with user-invocable: false must be hidden from the user-facing list.
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/commands/hidden.md",
        .data =
        \\---
        \\description: A hidden command
        \\user-invocable: false
        \\---
        \\body
        ,
    });

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    const wrote = try writeDynamicCommandsSection(buf.writer(), allocator, cwd, false);

    try testing.expect(wrote);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "/visible") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "/hidden") == null);
}
