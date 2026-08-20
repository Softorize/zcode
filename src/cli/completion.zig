const std = @import("std");
const std_io = @import("../core/std_io.zig");

/// Shell completion scripts ported in spirit from
/// claude-code-main/src/utils/completionCache.ts. zcode ships a
/// `zcode completion <shell>` subcommand that prints a completion
/// script to stdout; users redirect it themselves:
///
///     zcode completion bash > ~/.bash_completion.d/zcode
///     zcode completion zsh  > ~/.zfunc/_zcode
///     zcode completion fish > ~/.config/fish/completions/zcode.fish
///
/// We deliberately do NOT touch the user's shell rc file. Claude
/// Code's auto-install path decides for itself where the source
/// line belongs, which is convenient but has bitten users whose rc
/// files are managed by dotfiles frameworks. Print-only is simpler
/// and gives the user full control.
///
/// The scripts cover the top-level subcommands and the most-used
/// global flags. They don't try to exhaustively enumerate every
/// nested option -- the goal is "tab gets me to the right shape
/// of command quickly", not full-fidelity argument parsing in the
/// shell layer.
pub const Shell = enum {
    bash,
    zsh,
    fish,

    pub fn fromString(s: []const u8) ?Shell {
        if (std.mem.eql(u8, s, "bash")) return .bash;
        if (std.mem.eql(u8, s, "zsh")) return .zsh;
        if (std.mem.eql(u8, s, "fish")) return .fish;
        return null;
    }
};

/// Top-level subcommand verbs. Order matches args.zig's dispatch
/// order so the completions cover everything a user can type after
/// `zcode <TAB>`.
pub const SUBCOMMANDS = [_][]const u8{
    "run",
    "exec",
    "version",
    "models",
    "providers",
    "session",
    "agents",
    "daemon",
    "hooks",
    "marketplace",
    "plugins",
    "plugin",
    "commands",
    "command",
    "skills",
    "skill",
    "trust",
    "review",
    "mcp",
    "policy",
    "benchmark",
    "api",
    "update",
    "completion",
    "help",
};

/// Global flags that apply to most subcommands. The shell scripts
/// offer these after a `--<TAB>` at any completion position.
pub const GLOBAL_FLAGS = [_][]const u8{
    "--model",
    "--provider",
    "--agent",
    "--profile",
    "--approval-mode",
    "--sandbox",
    "--output-style",
    "--append-system-prompt",
    "--append-system-prompt-file",
    "--cwd",
    "--prompt-label",
    "--no-fullscreen",
    "--no-color",
    "--no-spinner",
    "--no-stream",
    "--no-thinking-summary",
    "--preprocessor",
    "--no-preprocessor",
    "--strict",
    "--approve-high",
    "--yolo",
    "--json",
    "--version",
    "--help",
};

/// Render the completion script for `shell` into an allocated
/// buffer. Caller owns the returned slice.
pub fn render(allocator: std.mem.Allocator, shell: Shell) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    switch (shell) {
        .bash => try renderBash(&out),
        .zsh => try renderZsh(&out),
        .fish => try renderFish(&out),
    }
    return out.toOwnedSlice();
}

fn renderBash(out: *std_io.StringBuilder) !void {
    try out.writer().writeAll("# zcode bash completion\n");
    try out.writer().writeAll("# Source this file from your .bashrc:\n");
    try out.writer().writeAll("#     [ -f ~/.bash_completion.d/zcode ] && source ~/.bash_completion.d/zcode\n");
    try out.writer().writeAll("_zcode_complete() {\n");
    try out.writer().writeAll("    local cur prev\n");
    try out.writer().writeAll("    COMPREPLY=()\n");
    try out.writer().writeAll("    cur=\"${COMP_WORDS[COMP_CWORD]}\"\n");
    try out.writer().writeAll("    prev=\"${COMP_WORDS[COMP_CWORD-1]}\"\n");
    try out.writer().writeAll("    if [[ ${cur} == --* ]] ; then\n");
    try out.writer().writeAll("        local flags=\"");
    try writeSpaceJoin(out, GLOBAL_FLAGS[0..]);
    try out.writer().writeAll("\"\n");
    try out.writer().writeAll("        COMPREPLY=( $(compgen -W \"${flags}\" -- ${cur}) )\n");
    try out.writer().writeAll("        return 0\n");
    try out.writer().writeAll("    fi\n");
    try out.writer().writeAll("    if [[ ${COMP_CWORD} -eq 1 ]] ; then\n");
    try out.writer().writeAll("        local cmds=\"");
    try writeSpaceJoin(out, SUBCOMMANDS[0..]);
    try out.writer().writeAll("\"\n");
    try out.writer().writeAll("        COMPREPLY=( $(compgen -W \"${cmds}\" -- ${cur}) )\n");
    try out.writer().writeAll("        return 0\n");
    try out.writer().writeAll("    fi\n");
    try out.writer().writeAll("}\n");
    try out.writer().writeAll("complete -F _zcode_complete zcode\n");
}

fn renderZsh(out: *std_io.StringBuilder) !void {
    try out.writer().writeAll("#compdef zcode\n");
    try out.writer().writeAll("# zcode zsh completion\n");
    try out.writer().writeAll("# Add the directory containing this file to $fpath and run compinit:\n");
    try out.writer().writeAll("#     fpath=(~/.zfunc $fpath)\n");
    try out.writer().writeAll("#     autoload -Uz compinit && compinit\n");
    try out.writer().writeAll("_zcode() {\n");
    try out.writer().writeAll("    local -a commands flags\n");
    try out.writer().writeAll("    commands=(\n");
    for (SUBCOMMANDS) |cmd| {
        try out.writer().print("        '{s}'\n", .{cmd});
    }
    try out.writer().writeAll("    )\n");
    try out.writer().writeAll("    flags=(\n");
    for (GLOBAL_FLAGS) |flag| {
        try out.writer().print("        '{s}'\n", .{flag});
    }
    try out.writer().writeAll("    )\n");
    try out.writer().writeAll("    if (( CURRENT == 2 )); then\n");
    try out.writer().writeAll("        _describe -t commands 'zcode command' commands\n");
    try out.writer().writeAll("    else\n");
    try out.writer().writeAll("        _describe -t flags 'zcode flag' flags\n");
    try out.writer().writeAll("    fi\n");
    try out.writer().writeAll("}\n");
    try out.writer().writeAll("compdef _zcode zcode\n");
}

fn renderFish(out: *std_io.StringBuilder) !void {
    try out.writer().writeAll("# zcode fish completion\n");
    try out.writer().writeAll("# Save to ~/.config/fish/completions/zcode.fish\n");
    // Subcommands: complete after `zcode` with no other args.
    for (SUBCOMMANDS) |cmd| {
        try out.writer().print("complete -c zcode -n \"__fish_use_subcommand\" -a \"{s}\"\n", .{cmd});
    }
    // Flags: always offered, regardless of position.
    for (GLOBAL_FLAGS) |flag| {
        // fish syntax strips the leading dashes for the `-l`/`-s` args.
        if (std.mem.startsWith(u8, flag, "--")) {
            try out.writer().print("complete -c zcode -l {s}\n", .{flag[2..]});
        }
    }
}

fn writeSpaceJoin(out: *std_io.StringBuilder, items: []const []const u8) !void {
    for (items, 0..) |item, i| {
        if (i > 0) try out.append(' ');
        try out.appendSlice(item);
    }
}

const testing = std.testing;

test "Shell.fromString recognises the three supported shells" {
    try testing.expectEqual(@as(?Shell, .bash), Shell.fromString("bash"));
    try testing.expectEqual(@as(?Shell, .zsh), Shell.fromString("zsh"));
    try testing.expectEqual(@as(?Shell, .fish), Shell.fromString("fish"));
    try testing.expectEqual(@as(?Shell, null), Shell.fromString("tcsh"));
    try testing.expectEqual(@as(?Shell, null), Shell.fromString(""));
}

test "render bash script contains core structure and subcommand list" {
    const out = try render(testing.allocator, .bash);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "_zcode_complete") != null);
    try testing.expect(std.mem.indexOf(u8, out, "complete -F _zcode_complete zcode") != null);
    try testing.expect(std.mem.indexOf(u8, out, "run") != null);
    try testing.expect(std.mem.indexOf(u8, out, "session") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--model") != null);
}

test "render zsh script starts with compdef and lists subcommands" {
    const out = try render(testing.allocator, .zsh);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "#compdef zcode"));
    try testing.expect(std.mem.indexOf(u8, out, "compdef _zcode zcode") != null);
    try testing.expect(std.mem.indexOf(u8, out, "'run'") != null);
    try testing.expect(std.mem.indexOf(u8, out, "'--provider'") != null);
}

test "render fish script emits per-subcommand complete lines" {
    const out = try render(testing.allocator, .fish);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "complete -c zcode -n \"__fish_use_subcommand\" -a \"run\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "complete -c zcode -l model") != null);
    try testing.expect(std.mem.indexOf(u8, out, "complete -c zcode -l no-fullscreen") != null);
}

test "render scripts cover every SUBCOMMAND entry" {
    // A regression guard: if a future refactor accidentally drops
    // one of the SUBCOMMANDS entries from a specific renderer, this
    // test catches it. Iterate over a typed array so the Shell
    // value is available as a runtime-usable slice, not a tuple of
    // mixed-enum expressions.
    const shells = [_]Shell{ .bash, .zsh, .fish };
    for (shells) |shell| {
        const out = try render(testing.allocator, shell);
        defer testing.allocator.free(out);
        for (SUBCOMMANDS) |cmd| {
            if (std.mem.indexOf(u8, out, cmd) == null) {
                std.debug.print("missing '{s}' in {s} script\n", .{ cmd, @tagName(shell) });
                try testing.expect(false);
            }
        }
    }
}
