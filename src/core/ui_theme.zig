const std = @import("std");

pub const SystemTheme = enum {
    dark,
    light,
};

pub const ThemeName = enum {
    dark,
    light,
    dark_daltonized,
    light_daltonized,
    dark_ansi,
    light_ansi,
};

pub const ThemeSetting = enum {
    auto,
    dark,
    light,
    dark_daltonized,
    light_daltonized,
    dark_ansi,
    light_ansi,
};

pub const Role = enum {
    reset,
    bold,
    italic,
    bold_italic,
    dim,
    underline,
    brand_accent,
    brand_accent_bold,
    brand_accent_dim,
    link,
    path,
    list,
    code_fence,
    code_comment,
    code_keyword,
    code_string,
    code_number,
    status_bg,
    error_prefix,
    prompt,
    heading_rule,
    approve_hl,
    deny_hl,
    heading1,
    heading2,
    heading3,
    warning,
    overlay_border,
    overlay_header,
    overlay_label,
    overlay_value,
    overlay_active,
    overlay_context,
    overlay_selection_bg,
    overlay_selection_fg,
    overlay_search,
    overlay_hint,
    approval_rail,
    approval_accept_fill,
    approval_deny_fill,
    approval_outline,
};

const Palette = struct {
    brand_accent: []const u8,
    brand_accent_bold: []const u8,
    brand_accent_dim: []const u8,
    link: []const u8,
    path: []const u8,
    list: []const u8,
    code_fence: []const u8,
    code_comment: []const u8,
    code_keyword: []const u8,
    code_string: []const u8,
    code_number: []const u8,
    status_bg: []const u8,
    error_prefix: []const u8,
    prompt: []const u8,
    heading_rule: []const u8,
    approve_hl: []const u8,
    deny_hl: []const u8,
    heading1: []const u8,
    heading2: []const u8,
    heading3: []const u8,
    warning: []const u8,
    overlay_border: []const u8,
    overlay_header: []const u8,
    overlay_label: []const u8,
    overlay_value: []const u8,
    overlay_active: []const u8,
    overlay_context: []const u8,
    overlay_selection_bg: []const u8,
    overlay_selection_fg: []const u8,
    overlay_search: []const u8,
    overlay_hint: []const u8,
    approval_rail: []const u8,
    approval_accept_fill: []const u8,
    approval_deny_fill: []const u8,
    approval_outline: []const u8,
};

const dark_palette = Palette{
    .brand_accent = "\x1b[38;2;95;212;160m",
    .brand_accent_bold = "\x1b[1;38;2;95;212;160m",
    .brand_accent_dim = "\x1b[38;2;58;128;98m",
    .link = "\x1b[38;5;75m\x1b[4m",
    .path = "\x1b[38;5;114m",
    .list = "\x1b[38;5;180m",
    .code_fence = "\x1b[38;5;240m",
    .code_comment = "\x1b[38;5;244m",
    .code_keyword = "\x1b[38;5;176m",
    .code_string = "\x1b[38;5;150m",
    .code_number = "\x1b[38;5;117m",
    .status_bg = "\x1b[48;5;236m\x1b[38;5;252m",
    .error_prefix = "\x1b[38;5;203m",
    .prompt = "\x1b[38;5;75m\x1b[1m",
    .heading_rule = "\x1b[38;5;240m",
    .approve_hl = "\x1b[38;5;114m\x1b[1m",
    .deny_hl = "\x1b[38;5;203m\x1b[1m",
    .heading1 = "\x1b[1;38;5;75m",
    .heading2 = "\x1b[1;38;5;114m",
    .heading3 = "\x1b[1;38;5;180m",
    .warning = "\x1b[38;5;180m",
    .overlay_border = "\x1b[38;5;240m",
    .overlay_header = "\x1b[38;5;75m\x1b[1m",
    .overlay_label = "\x1b[38;5;245m",
    .overlay_value = "\x1b[38;5;252m",
    .overlay_active = "\x1b[38;5;220m",
    .overlay_context = "\x1b[38;5;245m",
    .overlay_selection_bg = "\x1b[48;5;24m",
    .overlay_selection_fg = "\x1b[38;5;15m\x1b[1m",
    .overlay_search = "\x1b[38;5;114m",
    .overlay_hint = "\x1b[38;5;240m\x1b[3m",
    .approval_rail = "\x1b[38;2;95;212;160m",
    .approval_accept_fill = "\x1b[48;2;95;212;160m\x1b[38;2;11;18;22m\x1b[1m",
    .approval_deny_fill = "\x1b[48;2;217;95;114m\x1b[38;2;11;18;22m\x1b[1m",
    .approval_outline = "\x1b[38;2;200;210;220m\x1b[1m",
};

const light_palette = Palette{
    .brand_accent = "\x1b[38;2;215;119;87m",
    .brand_accent_bold = "\x1b[1;38;2;215;119;87m",
    .brand_accent_dim = "\x1b[38;2;170;130;120m",
    .link = "\x1b[38;2;87;105;247m\x1b[4m",
    .path = "\x1b[38;2;44;122;57m",
    .list = "\x1b[38;2;150;108;30m",
    .code_fence = "\x1b[38;5;245m",
    .code_comment = "\x1b[38;5;242m",
    .code_keyword = "\x1b[38;2;87;105;247m",
    .code_string = "\x1b[38;2;44;122;57m",
    .code_number = "\x1b[38;2;171;43;63m",
    .status_bg = "\x1b[48;2;235;236;240m\x1b[38;2;30;30;30m",
    .error_prefix = "\x1b[38;2;171;43;63m",
    .prompt = "\x1b[38;2;87;105;247m\x1b[1m",
    .heading_rule = "\x1b[38;5;247m",
    .approve_hl = "\x1b[38;2;44;122;57m\x1b[1m",
    .deny_hl = "\x1b[38;2;171;43;63m\x1b[1m",
    .heading1 = "\x1b[1;38;2;87;105;247m",
    .heading2 = "\x1b[1;38;2;44;122;57m",
    .heading3 = "\x1b[1;38;2;150;108;30m",
    .warning = "\x1b[38;2;150;108;30m",
    .overlay_border = "\x1b[38;5;247m",
    .overlay_header = "\x1b[38;2;87;105;247m\x1b[1m",
    .overlay_label = "\x1b[38;5;242m",
    .overlay_value = "\x1b[38;2;30;30;30m",
    .overlay_active = "\x1b[38;2;150;108;30m",
    .overlay_context = "\x1b[38;5;242m",
    .overlay_selection_bg = "\x1b[48;2;180;213;255m",
    .overlay_selection_fg = "\x1b[38;2;0;0;0m\x1b[1m",
    .overlay_search = "\x1b[38;2;44;122;57m",
    .overlay_hint = "\x1b[38;5;247m\x1b[3m",
    .approval_rail = "\x1b[38;2;87;105;247m",
    .approval_accept_fill = "\x1b[48;2;44;122;57m\x1b[38;2;255;255;255m\x1b[1m",
    .approval_deny_fill = "\x1b[48;2;171;43;63m\x1b[38;2;255;255;255m\x1b[1m",
    .approval_outline = "\x1b[38;2;87;105;247m\x1b[1m",
};

const dark_daltonized_palette = Palette{
    .brand_accent = "\x1b[38;2;255;153;51m",
    .brand_accent_bold = "\x1b[1;38;2;255;153;51m",
    .brand_accent_dim = "\x1b[38;2;160;110;72m",
    .link = "\x1b[38;2;153;204;255m\x1b[4m",
    .path = "\x1b[38;2;0;178;178m",
    .list = "\x1b[38;2;255;183;50m",
    .code_fence = "\x1b[38;5;245m",
    .code_comment = "\x1b[38;5;244m",
    .code_keyword = "\x1b[38;2;153;204;255m",
    .code_string = "\x1b[38;2;255;204;0m",
    .code_number = "\x1b[38;2;0;178;178m",
    .status_bg = "\x1b[48;2;52;58;66m\x1b[38;2;245;245;245m",
    .error_prefix = "\x1b[38;2;255;107;128m",
    .prompt = "\x1b[38;2;153;204;255m\x1b[1m",
    .heading_rule = "\x1b[38;5;245m",
    .approve_hl = "\x1b[38;2;153;204;255m\x1b[1m",
    .deny_hl = "\x1b[38;2;255;107;128m\x1b[1m",
    .heading1 = "\x1b[1;38;2;153;204;255m",
    .heading2 = "\x1b[1;38;2;255;183;50m",
    .heading3 = "\x1b[1;38;2;0;178;178m",
    .warning = "\x1b[38;2;255;183;50m",
    .overlay_border = "\x1b[38;5;245m",
    .overlay_header = "\x1b[38;2;153;204;255m\x1b[1m",
    .overlay_label = "\x1b[38;5;245m",
    .overlay_value = "\x1b[38;5;252m",
    .overlay_active = "\x1b[38;2;255;183;50m",
    .overlay_context = "\x1b[38;5;245m",
    .overlay_selection_bg = "\x1b[48;2;38;79;120m",
    .overlay_selection_fg = "\x1b[38;2;255;255;255m\x1b[1m",
    .overlay_search = "\x1b[38;2;153;204;255m",
    .overlay_hint = "\x1b[38;5;245m\x1b[3m",
    .approval_rail = "\x1b[38;2;153;204;255m",
    .approval_accept_fill = "\x1b[48;2;51;102;204m\x1b[38;2;255;255;255m\x1b[1m",
    .approval_deny_fill = "\x1b[48;2;153;51;51m\x1b[38;2;255;255;255m\x1b[1m",
    .approval_outline = "\x1b[38;2;255;183;50m\x1b[1m",
};

const light_daltonized_palette = Palette{
    .brand_accent = "\x1b[38;2;255;153;51m",
    .brand_accent_bold = "\x1b[1;38;2;255;153;51m",
    .brand_accent_dim = "\x1b[38;2;185;122;57m",
    .link = "\x1b[38;2;51;102;255m\x1b[4m",
    .path = "\x1b[38;2;0;102;153m",
    .list = "\x1b[38;2;255;153;0m",
    .code_fence = "\x1b[38;5;245m",
    .code_comment = "\x1b[38;5;242m",
    .code_keyword = "\x1b[38;2;51;102;255m",
    .code_string = "\x1b[38;2;255;153;0m",
    .code_number = "\x1b[38;2;0;102;153m",
    .status_bg = "\x1b[48;2;228;234;240m\x1b[38;2;20;20;20m",
    .error_prefix = "\x1b[38;2;204;0;0m",
    .prompt = "\x1b[38;2;51;102;255m\x1b[1m",
    .heading_rule = "\x1b[38;5;247m",
    .approve_hl = "\x1b[38;2;0;102;153m\x1b[1m",
    .deny_hl = "\x1b[38;2;204;0;0m\x1b[1m",
    .heading1 = "\x1b[1;38;2;51;102;255m",
    .heading2 = "\x1b[1;38;2;255;153;0m",
    .heading3 = "\x1b[1;38;2;0;102;153m",
    .warning = "\x1b[38;2;255;153;0m",
    .overlay_border = "\x1b[38;5;247m",
    .overlay_header = "\x1b[38;2;51;102;255m\x1b[1m",
    .overlay_label = "\x1b[38;5;242m",
    .overlay_value = "\x1b[38;2;20;20;20m",
    .overlay_active = "\x1b[38;2;255;153;0m",
    .overlay_context = "\x1b[38;5;242m",
    .overlay_selection_bg = "\x1b[48;2;180;213;255m",
    .overlay_selection_fg = "\x1b[38;2;0;0;0m\x1b[1m",
    .overlay_search = "\x1b[38;2;51;102;255m",
    .overlay_hint = "\x1b[38;5;247m\x1b[3m",
    .approval_rail = "\x1b[38;2;51;102;255m",
    .approval_accept_fill = "\x1b[48;2;0;102;153m\x1b[38;2;255;255;255m\x1b[1m",
    .approval_deny_fill = "\x1b[48;2;204;0;0m\x1b[38;2;255;255;255m\x1b[1m",
    .approval_outline = "\x1b[38;2;255;153;0m\x1b[1m",
};

const dark_ansi_palette = Palette{
    .brand_accent = "\x1b[95m",
    .brand_accent_bold = "\x1b[1;95m",
    .brand_accent_dim = "\x1b[35m",
    .link = "\x1b[94m\x1b[4m",
    .path = "\x1b[92m",
    .list = "\x1b[93m",
    .code_fence = "\x1b[37m",
    .code_comment = "\x1b[90m",
    .code_keyword = "\x1b[95m",
    .code_string = "\x1b[92m",
    .code_number = "\x1b[96m",
    .status_bg = "\x1b[100m\x1b[97m",
    .error_prefix = "\x1b[91m",
    .prompt = "\x1b[94m\x1b[1m",
    .heading_rule = "\x1b[90m",
    .approve_hl = "\x1b[92m\x1b[1m",
    .deny_hl = "\x1b[91m\x1b[1m",
    .heading1 = "\x1b[1;94m",
    .heading2 = "\x1b[1;92m",
    .heading3 = "\x1b[1;93m",
    .warning = "\x1b[93m",
    .overlay_border = "\x1b[90m",
    .overlay_header = "\x1b[94m\x1b[1m",
    .overlay_label = "\x1b[90m",
    .overlay_value = "\x1b[97m",
    .overlay_active = "\x1b[93m",
    .overlay_context = "\x1b[90m",
    .overlay_selection_bg = "\x1b[44m",
    .overlay_selection_fg = "\x1b[97m\x1b[1m",
    .overlay_search = "\x1b[92m",
    .overlay_hint = "\x1b[90m\x1b[3m",
    .approval_rail = "\x1b[95m",
    .approval_accept_fill = "\x1b[42m\x1b[30m\x1b[1m",
    .approval_deny_fill = "\x1b[41m\x1b[97m\x1b[1m",
    .approval_outline = "\x1b[97m\x1b[1m",
};

const light_ansi_palette = Palette{
    .brand_accent = "\x1b[35m",
    .brand_accent_bold = "\x1b[1;35m",
    .brand_accent_dim = "\x1b[95m",
    .link = "\x1b[34m\x1b[4m",
    .path = "\x1b[32m",
    .list = "\x1b[33m",
    .code_fence = "\x1b[90m",
    .code_comment = "\x1b[90m",
    .code_keyword = "\x1b[34m",
    .code_string = "\x1b[32m",
    .code_number = "\x1b[31m",
    .status_bg = "\x1b[47m\x1b[30m",
    .error_prefix = "\x1b[31m",
    .prompt = "\x1b[34m\x1b[1m",
    .heading_rule = "\x1b[90m",
    .approve_hl = "\x1b[32m\x1b[1m",
    .deny_hl = "\x1b[31m\x1b[1m",
    .heading1 = "\x1b[1;34m",
    .heading2 = "\x1b[1;32m",
    .heading3 = "\x1b[1;33m",
    .warning = "\x1b[33m",
    .overlay_border = "\x1b[90m",
    .overlay_header = "\x1b[34m\x1b[1m",
    .overlay_label = "\x1b[90m",
    .overlay_value = "\x1b[30m",
    .overlay_active = "\x1b[33m",
    .overlay_context = "\x1b[90m",
    .overlay_selection_bg = "\x1b[46m",
    .overlay_selection_fg = "\x1b[30m\x1b[1m",
    .overlay_search = "\x1b[32m",
    .overlay_hint = "\x1b[90m\x1b[3m",
    .approval_rail = "\x1b[34m",
    .approval_accept_fill = "\x1b[42m\x1b[97m\x1b[1m",
    .approval_deny_fill = "\x1b[41m\x1b[97m\x1b[1m",
    .approval_outline = "\x1b[34m\x1b[1m",
};

pub fn detectSystemTheme() SystemTheme {
    const raw = @import("env.zig").getenv("COLORFGBG") orelse return .dark;
    var it = std.mem.splitScalar(u8, raw, ';');
    var last: ?[]const u8 = null;
    while (it.next()) |part| last = part;
    const bg = last orelse return .dark;
    const bg_num = std.fmt.parseInt(u8, bg, 10) catch return .dark;
    if (bg_num <= 6 or bg_num == 8) return .dark;
    if (bg_num <= 15) return .light;
    return .dark;
}

pub fn resolveSetting(setting: ThemeSetting) ThemeName {
    return switch (setting) {
        .auto => switch (detectSystemTheme()) {
            .dark => .dark,
            .light => .light,
        },
        .dark => .dark,
        .light => .light,
        .dark_daltonized => .dark_daltonized,
        .light_daltonized => .light_daltonized,
        .dark_ansi => .dark_ansi,
        .light_ansi => .light_ansi,
    };
}

pub fn parseThemeName(raw: []const u8) ?ThemeName {
    return switch (normalize(raw) orelse return null) {
        .dark => .dark,
        .light => .light,
        .dark_daltonized => .dark_daltonized,
        .light_daltonized => .light_daltonized,
        .dark_ansi => .dark_ansi,
        .light_ansi => .light_ansi,
        .auto => null,
    };
}

pub fn parseThemeSetting(raw: []const u8) ?ThemeSetting {
    return normalize(raw);
}

fn normalize(raw: []const u8) ?ThemeSetting {
    if (raw.len == 0 or raw.len > 32) return null;
    var buf: [32]u8 = undefined;
    var len: usize = 0;
    for (raw) |ch| {
        if (len >= buf.len) return null;
        buf[len] = switch (ch) {
            'A'...'Z' => std.ascii.toLower(ch),
            '-' => '_',
            else => ch,
        };
        len += 1;
    }
    const normalized = buf[0..len];
    if (std.mem.eql(u8, normalized, "auto")) return .auto;
    if (std.mem.eql(u8, normalized, "dark")) return .dark;
    if (std.mem.eql(u8, normalized, "light")) return .light;
    if (std.mem.eql(u8, normalized, "dark_daltonized")) return .dark_daltonized;
    if (std.mem.eql(u8, normalized, "light_daltonized")) return .light_daltonized;
    if (std.mem.eql(u8, normalized, "dark_ansi")) return .dark_ansi;
    if (std.mem.eql(u8, normalized, "light_ansi")) return .light_ansi;
    return null;
}

pub fn formatThemeName(theme: ThemeName) []const u8 {
    return switch (theme) {
        .dark => "dark",
        .light => "light",
        .dark_daltonized => "dark-daltonized",
        .light_daltonized => "light-daltonized",
        .dark_ansi => "dark-ansi",
        .light_ansi => "light-ansi",
    };
}

pub fn formatThemeSetting(setting: ThemeSetting) []const u8 {
    return switch (setting) {
        .auto => "auto",
        .dark => "dark",
        .light => "light",
        .dark_daltonized => "dark-daltonized",
        .light_daltonized => "light-daltonized",
        .dark_ansi => "dark-ansi",
        .light_ansi => "light-ansi",
    };
}

pub fn themeFromOptions(options: anytype) ThemeName {
    const info = @typeInfo(@TypeOf(options));
    switch (info) {
        .pointer => |ptr| {
            if (@hasField(ptr.child, "theme")) return options.*.theme;
            if (@hasField(ptr.child, "theme_setting")) return resolveSetting(options.*.theme_setting);
        },
        else => {
            if (@hasField(@TypeOf(options), "theme")) return options.theme;
            if (@hasField(@TypeOf(options), "theme_setting")) return resolveSetting(options.theme_setting);
        },
    }
    return .dark;
}

pub fn ansiForOptions(options: anytype, comptime role: Role) []const u8 {
    return ansi(themeFromOptions(options), role);
}

pub fn ansi(theme: ThemeName, comptime role: Role) []const u8 {
    return switch (role) {
        .reset => "\x1b[0m",
        .bold => "\x1b[1m",
        .italic => "\x1b[3m",
        .bold_italic => "\x1b[1;3m",
        .dim => "\x1b[2m",
        .underline => "\x1b[4m",
        else => {
            const p = palette(theme);
            return switch (role) {
                .brand_accent => p.brand_accent,
                .brand_accent_bold => p.brand_accent_bold,
                .brand_accent_dim => p.brand_accent_dim,
                .link => p.link,
                .path => p.path,
                .list => p.list,
                .code_fence => p.code_fence,
                .code_comment => p.code_comment,
                .code_keyword => p.code_keyword,
                .code_string => p.code_string,
                .code_number => p.code_number,
                .status_bg => p.status_bg,
                .error_prefix => p.error_prefix,
                .prompt => p.prompt,
                .heading_rule => p.heading_rule,
                .approve_hl => p.approve_hl,
                .deny_hl => p.deny_hl,
                .heading1 => p.heading1,
                .heading2 => p.heading2,
                .heading3 => p.heading3,
                .warning => p.warning,
                .overlay_border => p.overlay_border,
                .overlay_header => p.overlay_header,
                .overlay_label => p.overlay_label,
                .overlay_value => p.overlay_value,
                .overlay_active => p.overlay_active,
                .overlay_context => p.overlay_context,
                .overlay_selection_bg => p.overlay_selection_bg,
                .overlay_selection_fg => p.overlay_selection_fg,
                .overlay_search => p.overlay_search,
                .overlay_hint => p.overlay_hint,
                .approval_rail => p.approval_rail,
                .approval_accept_fill => p.approval_accept_fill,
                .approval_deny_fill => p.approval_deny_fill,
                .approval_outline => p.approval_outline,
                else => unreachable,
            };
        },
    };
}

fn palette(theme: ThemeName) *const Palette {
    return switch (theme) {
        .dark => &dark_palette,
        .light => &light_palette,
        .dark_daltonized => &dark_daltonized_palette,
        .light_daltonized => &light_daltonized_palette,
        .dark_ansi => &dark_ansi_palette,
        .light_ansi => &light_ansi_palette,
    };
}

const testing = std.testing;

test "parse theme setting accepts hyphenated names" {
    try testing.expectEqual(ThemeSetting.dark_ansi, parseThemeSetting("dark-ansi").?);
    try testing.expectEqual(ThemeSetting.light_daltonized, parseThemeSetting("LIGHT-daltonized").?);
    try testing.expect(parseThemeSetting("missing") == null);
}

test "format theme name uses reference-style hyphenated names" {
    try testing.expectEqualStrings("dark-daltonized", formatThemeName(.dark_daltonized));
    try testing.expectEqualStrings("light-ansi", formatThemeSetting(.light_ansi));
}
