//! commands-missed-39 / commands-missed-41 / cli-flags-29: "import config from
//! another AI coding agent" (`/import [codex|gemini] [--dry-run]` and the
//! top-level `zcode import [codex|gemini]` subcommand).
//!
//! 2.1.261 ships this as a distinct feature from zcode's existing `session
//! import <bundle-path>` (restoring a previously-exported zcode session): this
//! module reads ANOTHER agent's on-disk config (Codex CLI's `~/.codex/`,
//! Gemini CLI's `~/.gemini/`) and translates the portable subset -- a
//! project-level memory/instructions file and any configured MCP servers --
//! into zcode's own config surface (`CLAUDE.md` and `.mcp.json`).
//!
//! Scope: best-effort field mapping, not a byte-exact port (the source
//! schemas are external and may drift). `dry_run` never writes -- it only
//! reports what a real run would do. A real run never deletes or reorders
//! anything already in the target files; it only appends/merges.

const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("std_io.zig");
const paths = @import("paths.zig");
const parse_helpers = @import("parse_helpers.zig");
const env = @import("env.zig");
const rng = @import("rng.zig");

pub const Source = enum {
    codex,
    gemini,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .codex => "codex",
            .gemini => "gemini",
        };
    }
};

/// Parse the `[codex|gemini]` positional argument. Anything else (including
/// empty) is rejected -- mirrors the reference's restrictive allowlist
/// (`["codex","gemini","--dry-run","--yes"]`).
pub fn parseSource(raw: []const u8) ?Source {
    if (std.mem.eql(u8, raw, "codex")) return .codex;
    if (std.mem.eql(u8, raw, "gemini")) return .gemini;
    return null;
}

/// Resolve `$HOME` (through `core/env.zig` so tests can override it via
/// `env.setOverride("HOME", ...)`). Empty string when unset.
fn homeDir(allocator: std.mem.Allocator) ![]u8 {
    return env.getOwned(allocator, "HOME") catch allocator.dupe(u8, "");
}

fn fileExists(path: []const u8) bool {
    if (std.Io.Dir.cwd().access(rt.io, path, .{})) |_| return true else |_| return false;
}

/// Which project-level memory file a source uses, and where its top-level
/// config directory would live -- pure so `detect`/tests do not need real
/// disk access to reason about paths.
fn memoryFileName(source: Source) []const u8 {
    return switch (source) {
        .codex => "AGENTS.md",
        .gemini => "GEMINI.md",
    };
}

fn homeConfigSubdir(source: Source) []const u8 {
    return switch (source) {
        .codex => ".codex",
        .gemini => ".gemini",
    };
}

fn homeConfigFileName(source: Source) []const u8 {
    return switch (source) {
        .codex => "config.toml",
        .gemini => "settings.json",
    };
}

pub const Detected = struct {
    /// Absolute path to the source's home config file, or null if not found.
    home_config_path: ?[]u8 = null,
    /// Absolute path to the project-level memory file (AGENTS.md/GEMINI.md)
    /// found in `cwd`, or null.
    project_memory_path: ?[]u8 = null,

    pub fn deinit(self: *Detected, allocator: std.mem.Allocator) void {
        if (self.home_config_path) |p| allocator.free(p);
        if (self.project_memory_path) |p| allocator.free(p);
    }
};

/// Look for `source`'s home config file and a project-level memory file under
/// `cwd`. Never fails: any resolution error just leaves the corresponding
/// field null.
pub fn detect(allocator: std.mem.Allocator, cwd: []const u8, source: Source) !Detected {
    var out = Detected{};

    const home = homeDir(allocator) catch try allocator.dupe(u8, "");
    defer allocator.free(home);
    if (home.len > 0) {
        const p = try std.fs.path.join(allocator, &.{ home, homeConfigSubdir(source), homeConfigFileName(source) });
        if (fileExists(p)) {
            out.home_config_path = p;
        } else {
            allocator.free(p);
        }
    }

    const mem_path = try std.fs.path.join(allocator, &.{ cwd, memoryFileName(source) });
    if (fileExists(mem_path)) {
        out.project_memory_path = mem_path;
    } else {
        allocator.free(mem_path);
    }

    return out;
}

/// Extract the `mcpServers` object from a Gemini CLI `settings.json` body as a
/// standalone, re-serialized JSON object string (e.g. `{"foo":{"command":...}}`),
/// or null when absent/malformed. Pure (bytes in, bytes out).
pub fn extractGeminiMcpServersJson(allocator: std.mem.Allocator, settings_json: []const u8) !?[]u8 {
    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, parse_helpers.stripBom(settings_json)) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const servers = parsed.value.object.get("mcpServers") orelse return null;
    if (servers != .object) return null;

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(servers, .{}, out.writer());
    return try out.toOwnedSlice();
}

/// Extract `[mcp_servers.NAME]` tables from a Codex `config.toml` body and
/// re-render them as a JSON object string in the same shape Claude Code /
/// zcode's `.mcp.json` `mcpServers` map uses: `{"NAME":{"command":"...",
/// "args":["..."]}}`. Best-effort line scanner (not a full TOML parser) --
/// tolerates any table it cannot fully parse by skipping it. Returns null when
/// no `mcp_servers.*` table is found.
pub fn extractCodexMcpServersJson(allocator: std.mem.Allocator, toml: []const u8) !?[]u8 {
    var names: std.array_list.Managed([]const u8) = .init(allocator);
    defer names.deinit();
    var commands: std.array_list.Managed(?[]const u8) = .init(allocator);
    defer commands.deinit();
    var args_lines: std.array_list.Managed(?[]const u8) = .init(allocator);
    defer args_lines.deinit();

    var current: ?usize = null; // index into names/commands/args_lines of the table currently being read
    var lines = std.mem.splitScalar(u8, toml, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line.len > 2 and line[0] == '[' and line[line.len - 1] == ']') {
            const header = line[1 .. line.len - 1];
            const prefix = "mcp_servers.";
            if (std.mem.startsWith(u8, header, prefix)) {
                const name = std.mem.trim(u8, header[prefix.len..], "\"' ");
                if (name.len == 0) {
                    current = null;
                    continue;
                }
                try names.append(name);
                try commands.append(null);
                try args_lines.append(null);
                current = names.items.len - 1;
            } else {
                current = null;
            }
            continue;
        }

        const idx = current orelse continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "command")) {
            commands.items[idx] = std.mem.trim(u8, value, "\"'");
        } else if (std.mem.eql(u8, key, "args")) {
            args_lines.items[idx] = value; // raw `["a", "b"]`-ish text; re-parsed below
        }
    }

    if (names.items.len == 0) return null;

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();
    try w.writeByte('{');
    for (names.items, 0..) |name, i| {
        if (i > 0) try w.writeByte(',');
        try std.json.Stringify.value(name, .{}, w);
        try w.writeAll(":{\"command\":");
        try std.json.Stringify.value(commands.items[i] orelse "", .{}, w);
        try w.writeAll(",\"args\":");
        try writeTomlArgsAsJsonArray(w, args_lines.items[i]);
        try w.writeByte('}');
    }
    try w.writeByte('}');
    return try out.toOwnedSlice();
}

/// Render a TOML-ish `["a", "b", "c"]` array literal as a JSON array. Falls
/// back to `[]` for anything that is not a bracketed literal (best-effort:
/// this is not a TOML parser).
fn writeTomlArgsAsJsonArray(w: *std.Io.Writer, raw: ?[]const u8) !void {
    const value = raw orelse "";
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') {
        try w.writeAll("[]");
        return;
    }
    const inner = trimmed[1 .. trimmed.len - 1];
    try w.writeByte('[');
    var first = true;
    var parts = std.mem.splitScalar(u8, inner, ',');
    while (parts.next()) |part| {
        const item = std.mem.trim(u8, part, " \t\"'");
        if (item.len == 0) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try std.json.Stringify.value(item, .{}, w);
    }
    try w.writeByte(']');
}

/// Merge a `{"name":{...}, ...}` JSON object of MCP servers into the
/// `mcpServers` key of `<cwd>/.mcp.json`, creating the file if absent.
/// Existing entries with the SAME name are overwritten by the import (an
/// explicit re-import is assumed to be intentional); every other entry and
/// every other top-level field is preserved untouched. Atomic write.
pub fn mergeMcpServers(allocator: std.mem.Allocator, cwd: []const u8, servers_json: []const u8) !void {
    var incoming = parse_helpers.parseJsonBounded(std.json.Value, allocator, servers_json) catch return error.InvalidServersJson;
    defer incoming.deinit();
    if (incoming.value != .object) return error.InvalidServersJson;

    const path = try std.fs.path.join(allocator, &.{ cwd, ".mcp.json" });
    defer allocator.free(path);

    const existing_bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(existing_bytes);

    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |*p| p.deinit();
    if (existing_bytes.len > 0) {
        if (parse_helpers.parseJsonBounded(std.json.Value, allocator, parse_helpers.stripBom(existing_bytes))) |p| {
            parsed = p;
        } else |_| {}
    }

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();

    var servers_map: std.json.ObjectMap = .empty;
    if (parsed) |p| {
        if (p.value == .object) {
            if (p.value.object.get("mcpServers")) |existing_servers| {
                if (existing_servers == .object) {
                    var it = existing_servers.object.iterator();
                    while (it.next()) |kv| try servers_map.put(sa, kv.key_ptr.*, kv.value_ptr.*);
                }
            }
        }
    }
    var new_it = incoming.value.object.iterator();
    while (new_it.next()) |kv| try servers_map.put(sa, kv.key_ptr.*, kv.value_ptr.*);

    var root_map: std.json.ObjectMap = .empty;
    if (parsed) |p| {
        if (p.value == .object) {
            var it = p.value.object.iterator();
            while (it.next()) |kv| {
                if (std.mem.eql(u8, kv.key_ptr.*, "mcpServers")) continue;
                try root_map.put(sa, kv.key_ptr.*, kv.value_ptr.*);
            }
        }
    }
    try root_map.put(sa, "mcpServers", .{ .object = servers_map });

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(std.json.Value{ .object = root_map }, .{ .whitespace = .indent_2 }, out.writer());
    try out.writer().writeByte('\n');

    try writeFileAtomic(allocator, path, out.items());
}

const IMPORT_MARKER_PREFIX = "<!-- zcode import: ";

/// Append `text` (from a source's memory file) to `<cwd>/CLAUDE.md` under a
/// clearly-labelled section, unless a section with the SAME marker (source +
/// origin path) is already present -- makes a re-run idempotent instead of
/// duplicating the block every time.
pub fn appendMemoryImport(allocator: std.mem.Allocator, cwd: []const u8, source: Source, origin_path: []const u8, text: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ cwd, "CLAUDE.md" });
    defer allocator.free(path);

    const marker = try std.fmt.allocPrint(allocator, "{s}{s}:{s} -->", .{ IMPORT_MARKER_PREFIX, source.label(), origin_path });
    defer allocator.free(marker);

    const existing = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(existing);

    if (std.mem.indexOf(u8, existing, marker) != null) return; // already imported

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().writeAll(existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') try out.writer().writeByte('\n');
    try out.writer().print("\n{s}\n## Imported from {s} ({s})\n\n{s}\n", .{ marker, source.label(), origin_path, std.mem.trim(u8, text, " \t\r\n") });

    try writeFileAtomic(allocator, path, out.items());
}

/// Result of `runImport`, formatted as a human-readable report.
pub fn runImport(allocator: std.mem.Allocator, cwd: []const u8, source: Source, dry_run: bool) ![]u8 {
    var detected = try detect(allocator, cwd, source);
    defer detected.deinit(allocator);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();
    try w.print("import from {s}{s}\n", .{ source.label(), if (dry_run) " (dry run)" else "" });

    if (detected.home_config_path == null and detected.project_memory_path == null) {
        try w.print("  no {s} config found on this machine (checked ~/{s}/{s} and ./{s})\n", .{
            source.label(),
            homeConfigSubdir(source),
            homeConfigFileName(source),
            memoryFileName(source),
        });
        return try out.toOwnedSlice();
    }

    if (detected.project_memory_path) |mem_path| {
        const text = std.Io.Dir.cwd().readFileAlloc(rt.io, mem_path, allocator, .limited(1024 * 1024)) catch null;
        if (text) |t| {
            defer allocator.free(t);
            if (dry_run) {
                try w.print("  would import {d} byte(s) of instructions from {s} into CLAUDE.md\n", .{ t.len, mem_path });
            } else {
                appendMemoryImport(allocator, cwd, source, mem_path, t) catch |err| {
                    try w.print("  failed to import {s} into CLAUDE.md: {s}\n", .{ mem_path, @errorName(err) });
                    return try out.toOwnedSlice();
                };
                try w.print("  imported instructions from {s} into CLAUDE.md\n", .{mem_path});
            }
        }
    }

    if (detected.home_config_path) |cfg_path| {
        const cfg_text = std.Io.Dir.cwd().readFileAlloc(rt.io, cfg_path, allocator, .limited(1024 * 1024)) catch null;
        if (cfg_text) |t| {
            defer allocator.free(t);
            const servers_json = switch (source) {
                .codex => try extractCodexMcpServersJson(allocator, t),
                .gemini => try extractGeminiMcpServersJson(allocator, t),
            };
            if (servers_json) |sj| {
                defer allocator.free(sj);
                if (dry_run) {
                    try w.print("  would merge MCP servers from {s} into .mcp.json: {s}\n", .{ cfg_path, sj });
                } else {
                    mergeMcpServers(allocator, cwd, sj) catch |err| {
                        try w.print("  failed to merge MCP servers from {s}: {s}\n", .{ cfg_path, @errorName(err) });
                        return try out.toOwnedSlice();
                    };
                    try w.print("  merged MCP servers from {s} into .mcp.json\n", .{cfg_path});
                }
            } else {
                try w.print("  found {s} but no MCP servers to import\n", .{cfg_path});
            }
        }
    }

    if (dry_run) try w.writeAll("(dry run) no changes made\n");
    return try out.toOwnedSlice();
}

/// `zcode import [codex|gemini] [--dry-run]` CLI entry point (cli-flags-29).
/// NOT wired into `src/cli/args.zig` yet (that file is owned by another work
/// package) -- see the wp1b-commands-new report for the one-line dispatch this
/// needs once args.zig grows an `.import_agent_config` CommandKind. Exposed
/// here so the wiring is a thin call-through when that lands.
pub fn runImportSubcommand(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !u8 {
    var dry_run = false;
    var source_arg: ?[]const u8 = null;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, a, "--yes")) {
            // accepted for reference-flag parity; zcode's local write path has
            // no interactive picker to skip, so this is currently a no-op.
        } else if (source_arg == null) {
            source_arg = a;
        }
    }

    const raw = source_arg orelse {
        try std_io.stderrWriter().writeAll("usage: zcode import <codex|gemini> [--dry-run]\n");
        return 2;
    };
    const source = parseSource(raw) orelse {
        try std_io.stderrWriter().print("error: unknown import source '{s}' (expected codex or gemini)\n", .{raw});
        return 2;
    };

    const report = try runImport(allocator, cwd, source, dry_run);
    defer allocator.free(report);
    try std_io.stdoutWriter().writeAll(report);
    return 0;
}

fn writeFileAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(target)) |dir| {
        if (dir.len > 0) std.Io.Dir.cwd().createDirPath(rt.io, dir) catch {};
    }
    var nonce: [8]u8 = undefined;
    rng.bytes(&nonce);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}{x}{x}{x}{x}{x}{x}{x}", .{
        target, nonce[0], nonce[1], nonce[2], nonce[3], nonce[4], nonce[5], nonce[6], nonce[7],
    });
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

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

test "parseSource accepts only codex/gemini" {
    try testing.expectEqual(Source.codex, parseSource("codex").?);
    try testing.expectEqual(Source.gemini, parseSource("gemini").?);
    try testing.expect(parseSource("cursor") == null);
    try testing.expect(parseSource("") == null);
    try testing.expect(parseSource("--dry-run") == null);
}

test "extractGeminiMcpServersJson pulls the mcpServers object" {
    const alloc = testing.allocator;
    const settings =
        \\{"theme":"dark","mcpServers":{"fs":{"command":"npx","args":["mcp-fs"]}}}
    ;
    const out = (try extractGeminiMcpServersJson(alloc, settings)).?;
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"fs\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "mcp-fs") != null);
}

test "extractGeminiMcpServersJson returns null when absent" {
    const alloc = testing.allocator;
    try testing.expect((try extractGeminiMcpServersJson(alloc, "{\"theme\":\"dark\"}")) == null);
}

test "extractCodexMcpServersJson reads mcp_servers tables from toml" {
    const alloc = testing.allocator;
    const toml =
        \\[profile]
        \\default = "o3"
        \\
        \\[mcp_servers.fs]
        \\command = "npx"
        \\args = ["-y", "mcp-fs"]
        \\
        \\[mcp_servers.git]
        \\command = "uvx"
        \\args = []
    ;
    const out = (try extractCodexMcpServersJson(alloc, toml)).?;
    defer alloc.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    const fs = parsed.value.object.get("fs").?;
    try testing.expectEqualStrings("npx", fs.object.get("command").?.string);
    try testing.expectEqual(@as(usize, 2), fs.object.get("args").?.array.items.len);
    try testing.expectEqualStrings("-y", fs.object.get("args").?.array.items[0].string);
    const git = parsed.value.object.get("git").?;
    try testing.expectEqualStrings("uvx", git.object.get("command").?.string);
    try testing.expectEqual(@as(usize, 0), git.object.get("args").?.array.items.len);
}

test "extractCodexMcpServersJson returns null with no mcp_servers table" {
    const alloc = testing.allocator;
    try testing.expect((try extractCodexMcpServersJson(alloc, "[profile]\ndefault = \"o3\"\n")) == null);
}

test "detect finds a project memory file and reports no home config" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(cwd);

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "AGENTS.md", .data = "Follow these rules." });

    try env.setOverride("HOME", "/nonexistent-zcode-test-home");
    defer env.clearOverrides();

    var detected = try detect(alloc, cwd, .codex);
    defer detected.deinit(alloc);
    try testing.expect(detected.home_config_path == null);
    try testing.expect(detected.project_memory_path != null);
    try testing.expect(std.mem.endsWith(u8, detected.project_memory_path.?, "AGENTS.md"));
}

test "appendMemoryImport is idempotent on a second run" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(cwd);

    try appendMemoryImport(alloc, cwd, .codex, "/home/u/AGENTS.md", "Always run tests before committing.");
    try appendMemoryImport(alloc, cwd, .codex, "/home/u/AGENTS.md", "Always run tests before committing.");

    const path = try std.fs.path.join(alloc, &.{ cwd, "CLAUDE.md" });
    defer alloc.free(path);
    const text = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, alloc, .limited(1024 * 1024));
    defer alloc.free(text);

    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, text, idx, "Always run tests before committing.")) |pos| {
        count += 1;
        idx = pos + 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "mergeMcpServers preserves existing unrelated servers and top-level fields" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(cwd);

    const path = try std.fs.path.join(alloc, &.{ cwd, ".mcp.json" });
    defer alloc.free(path);
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".mcp.json",
        .data = "{\"mcpServers\":{\"existing\":{\"command\":\"foo\"}},\"otherTopLevel\":true}",
    });

    try mergeMcpServers(alloc, cwd, "{\"fs\":{\"command\":\"npx\",\"args\":[\"mcp-fs\"]}}");

    const text = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, alloc, .limited(1024 * 1024));
    defer alloc.free(text);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    defer parsed.deinit();
    const servers = parsed.value.object.get("mcpServers").?.object;
    try testing.expect(servers.get("existing") != null);
    try testing.expect(servers.get("fs") != null);
    try testing.expect(parsed.value.object.get("otherTopLevel").?.bool == true);
}

test "runImportSubcommand rejects an unknown source" {
    const alloc = testing.allocator;
    const code = try runImportSubcommand(alloc, ".", &.{"cursor"});
    try testing.expectEqual(@as(u8, 2), code);
}

test "runImportSubcommand reports nothing found for a clean cwd" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(cwd);

    try env.setOverride("HOME", "/nonexistent-zcode-test-home");
    defer env.clearOverrides();

    const code = try runImportSubcommand(alloc, cwd, &.{ "codex", "--dry-run" });
    try testing.expectEqual(@as(u8, 0), code);
}
