pub const Action = enum {
    transcript,
    tasks,
    teams,
    bridge,
    files,
    search,
    model,
    think,
    auto,
    theme,
    brief,
};

pub const RowKind = enum {
    suggestion,
    queue,
    stash,
    notice,
};

pub const StripKind = enum {
    queue,
    task,
    stash,
    notification,
    runtime,
};

pub const SuggestionSource = enum {
    workspace,
    history,
    command,
    reference,
    agent,
    team,
    mcp_resource,
    mcp_prompt,
    queue,
    notice,
};

pub const NoticeTone = enum {
    accent,
    dim,
    plain,
};

pub const Row = struct {
    kind: RowKind,
    primary: []const u8,
    secondary: []const u8 = "",
    tag: []const u8 = "",
    source: SuggestionSource = .notice,
    tone: NoticeTone = .plain,
    selectable: bool = false,
};

pub const StripItem = struct {
    kind: StripKind,
    title: []const u8,
    body: []const u8 = "",
    tag: []const u8 = "",
    tone: NoticeTone = .plain,
    focusable: bool = false,
    dismissable: bool = false,
};

pub const ordered_actions = [_]Action{
    .transcript,
    .tasks,
    .teams,
    .bridge,
    .files,
    .search,
    .model,
    .think,
    .auto,
    .theme,
    .brief,
};

pub fn label(action: Action) []const u8 {
    return switch (action) {
        .transcript => "Transcript",
        .tasks => "Tasks",
        .teams => "Teams",
        .bridge => "Bridge",
        .files => "Files",
        .search => "Search",
        .model => "Model",
        .think => "Think",
        .auto => "Auto",
        .theme => "Theme",
        .brief => "Brief",
    };
}

pub fn shortcut(action: Action) []const u8 {
    return switch (action) {
        .transcript => "Ctrl+O",
        .tasks => "Ctrl+T",
        .teams => "/teams",
        .bridge => "/bridge",
        .files => "Ctrl+P",
        .search => "Ctrl+Shift+F",
        .model => "Alt+P",
        .think => "Alt+T",
        .auto => "/yolo",
        .theme => "/theme",
        .brief => "Ctrl+Shift+B",
    };
}

pub fn defaultTag(kind: RowKind, source: SuggestionSource) []const u8 {
    return switch (kind) {
        .suggestion => switch (source) {
            .workspace => "start",
            .history => "recent",
            .command => "cmd",
            .reference => "file",
            .agent => "agent",
            .team => "team",
            .mcp_resource => "mcp",
            .mcp_prompt => "mcp",
            .queue => "queued",
            .notice => "",
        },
        .queue => "queued",
        .stash => "stash",
        .notice => "",
    };
}
