//! Pure parser for inbound terminal-response escape sequences.
//!
//! Terminals answer queries (DECRQM, DA1, DA2, OSC 11, XTVERSION, ...) by
//! writing escape sequences back on the same input stream the keyboard uses.
//! These look superficially like keypresses but are syntactically
//! distinguishable: no physical key produces `CSI ? ... c` or `CSI ? ... $ y`,
//! so they can be recognized and routed out of the keypress path instead of
//! leaking into the prompt as garbage bytes.
//!
//! This mirrors the reference `parseTerminalResponse` in
//! `src/ink/parse-keypress.ts`. The CSI-framed responses (DECRPM / DA1 / DA2 /
//! kitty-flags / DSR cursor-position) landed in terminal-01. The OSC
//! (`ESC ] code ; data BEL/ST`) and DCS XTVERSION (`ESC P > | name BEL/ST`)
//! variants land in terminal-02 (Task 11) where the input reader is taught to
//! read past a BEL / ST terminator.
//!
//! No allocation and no IO. The `[]const u8` payload slices point into the
//! caller's `seq` buffer, so they are only valid until the next read.

const std = @import("std");

/// DECRPM status values (response to DECRQM). Mirrors the reference
/// `DECRPM_STATUS` table.
pub const DecrpmStatus = struct {
    pub const NOT_RECOGNIZED: u32 = 0;
    pub const SET: u32 = 1;
    pub const RESET: u32 = 2;
    pub const PERMANENTLY_SET: u32 = 3;
    pub const PERMANENTLY_RESET: u32 = 4;
};

/// A response sequence received from the terminal (not a keypress).
/// Emitted in answer to queries like DECRQM, DA1, OSC 11, etc.
pub const TerminalResponse = union(enum) {
    /// DECRPM: answer to DECRQM (request DEC private mode status).
    decrpm: struct { mode: u32, status: u32 },
    /// DA1: primary device attributes. `params` is the raw numeric param
    /// slice (e.g. "1;2") pointing into the caller's buffer.
    da1: []const u8,
    /// DA2: secondary device attributes (terminal version info).
    da2: []const u8,
    /// Kitty keyboard protocol: current flags (answer to CSI ? u).
    kitty_keyboard: u32,
    /// DSR: cursor position report (answer to CSI 6 n), private form.
    cursor_position: struct { row: u32, col: u32 },
    /// OSC response: generic operating-system-command reply (e.g. OSC 11 bg
    /// color).
    osc: struct { code: u32, data: []const u8 },
    /// XTVERSION: terminal name/version string (answer to CSI > 0 q).
    xtversion: []const u8,
};

/// Try to recognize `seq` as a terminal response. Returns null if it is not a
/// known response pattern (i.e. it should be treated as a keypress).
///
/// `seq` is the full sequence including the framing escape (`\x1b[`, `\x1b]`
/// or `\x1bP`).
pub fn parse(seq: []const u8) ?TerminalResponse {
    // CSI-framed responses: ESC [ ...
    if (std.mem.startsWith(u8, seq, "\x1b[")) {
        return parseCsi(seq[2..]);
    }

    // DCS-framed XTVERSION: ESC P > | name (BEL | ST)
    if (std.mem.startsWith(u8, seq, "\x1bP")) {
        return parseDcs(seq[2..]);
    }

    // OSC-framed responses: ESC ] code ; data (BEL | ST)
    if (std.mem.startsWith(u8, seq, "\x1b]")) {
        return parseOsc(seq[2..]);
    }

    return null;
}

/// Strip a trailing OSC/DCS string terminator (BEL `\x07` or ST `ESC \`)
/// from `body`, returning the payload before it. Returns null if no
/// terminator is present.
fn stripStringTerminator(body: []const u8) ?[]const u8 {
    if (body.len >= 1 and body[body.len - 1] == 0x07) {
        return body[0 .. body.len - 1];
    }
    if (body.len >= 2 and body[body.len - 2] == 0x1b and body[body.len - 1] == '\\') {
        return body[0 .. body.len - 2];
    }
    return null;
}

/// Parse the body of a DCS-framed sequence (everything after `ESC P`).
/// Only XTVERSION (`> | name (BEL | ST)`) is recognized.
fn parseDcs(body: []const u8) ?TerminalResponse {
    // XTVERSION reply: starts with ">|" then the name, then the terminator.
    if (!std.mem.startsWith(u8, body, ">|")) return null;
    const after = body[2..];
    const name = stripStringTerminator(after) orelse return null;
    return .{ .xtversion = name };
}

/// Parse the body of an OSC-framed sequence (everything after `ESC ]`).
/// Shape: `code ; data (BEL | ST)`.
fn parseOsc(body: []const u8) ?TerminalResponse {
    const payload = stripStringTerminator(body) orelse return null;
    const semi = std.mem.indexOfScalar(u8, payload, ';') orelse return null;
    const code = parseSingleNumber(payload[0..semi]) orelse return null;
    return .{ .osc = .{ .code = code, .data = payload[semi + 1 ..] } };
}

/// Parse the body of a CSI-framed response (everything after `ESC [`).
fn parseCsi(body: []const u8) ?TerminalResponse {
    if (body.len == 0) return null;

    // The private `?` marker distinguishes DECRPM / DA1 / kitty-flags / DSR
    // from ordinary key sequences (and disambiguates DSR cursor reports from
    // modified-F3 keys, which lack the `?`).
    if (body[0] == '?') {
        const rest = body[1..];
        if (rest.len == 0) return null;
        const final = rest[rest.len - 1];
        const params = rest[0 .. rest.len - 1];

        switch (final) {
            // DA1: CSI ? params c
            'c' => {
                if (!validParamChars(params)) return null;
                return .{ .da1 = params };
            },
            // Kitty keyboard flags: CSI ? flags u   (single numeric field)
            'u' => {
                const flags = parseSingleNumber(params) orelse return null;
                return .{ .kitty_keyboard = flags };
            },
            // DECRPM: CSI ? mode ; status $ y
            'y' => {
                // Trailing must be "$y"; strip the '$' off the params tail.
                if (params.len == 0 or params[params.len - 1] != '$') return null;
                const fields = params[0 .. params.len - 1];
                const two = parseTwoNumbers(fields) orelse return null;
                return .{ .decrpm = .{ .mode = two[0], .status = two[1] } };
            },
            // DSR cursor position (private form): CSI ? row ; col R
            'R' => {
                const two = parseTwoNumbers(params) orelse return null;
                return .{ .cursor_position = .{ .row = two[0], .col = two[1] } };
            },
            else => return null,
        }
    }

    // DA2: CSI > params c
    if (body[0] == '>') {
        const rest = body[1..];
        if (rest.len == 0 or rest[rest.len - 1] != 'c') return null;
        const params = rest[0 .. rest.len - 1];
        if (!validParamChars(params)) return null;
        return .{ .da2 = params };
    }

    return null;
}

/// True when every byte is a digit or a ';' separator. Empty is allowed
/// (DA1/DA2 may report no params).
fn validParamChars(s: []const u8) bool {
    for (s) |ch| {
        if ((ch < '0' or ch > '9') and ch != ';') return false;
    }
    return true;
}

/// Parse a single all-digit field into a u32, or null if empty / non-digit.
fn parseSingleNumber(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var value: u32 = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return null;
        value = value * 10 + (ch - '0');
    }
    return value;
}

/// Parse exactly "a;b" into two u32 values, or null on any mismatch.
fn parseTwoNumbers(s: []const u8) ?[2]u32 {
    const semi = std.mem.indexOfScalar(u8, s, ';') orelse return null;
    const a = parseSingleNumber(s[0..semi]) orelse return null;
    const b = parseSingleNumber(s[semi + 1 ..]) orelse return null;
    return .{ a, b };
}

test "parse DECRPM" {
    const r = parse("\x1b[?2026;1$y") orelse return error.TestUnexpectedResult;
    try std.testing.expect(r == .decrpm);
    try std.testing.expectEqual(@as(u32, 2026), r.decrpm.mode);
    try std.testing.expectEqual(@as(u32, 1), r.decrpm.status);
}

test "parse DA1" {
    const r = parse("\x1b[?1;2c") orelse return error.TestUnexpectedResult;
    try std.testing.expect(r == .da1);
    try std.testing.expectEqualStrings("1;2", r.da1);
}

test "parse DA1 with no params" {
    const r = parse("\x1b[?c") orelse return error.TestUnexpectedResult;
    try std.testing.expect(r == .da1);
    try std.testing.expectEqualStrings("", r.da1);
}

test "parse DA2" {
    const r = parse("\x1b[>0;276;0c") orelse return error.TestUnexpectedResult;
    try std.testing.expect(r == .da2);
    try std.testing.expectEqualStrings("0;276;0", r.da2);
}

test "parse kitty keyboard flags" {
    const r = parse("\x1b[?5u") orelse return error.TestUnexpectedResult;
    try std.testing.expect(r == .kitty_keyboard);
    try std.testing.expectEqual(@as(u32, 5), r.kitty_keyboard);
}

test "parse cursor position" {
    const r = parse("\x1b[?12;34R") orelse return error.TestUnexpectedResult;
    try std.testing.expect(r == .cursor_position);
    try std.testing.expectEqual(@as(u32, 12), r.cursor_position.row);
    try std.testing.expectEqual(@as(u32, 34), r.cursor_position.col);
}

test "plain key sequence is not a response" {
    try std.testing.expect(parse("\x1b[A") == null);
}

test "modified F3 (no private marker) is not a cursor report" {
    // Shift+F3 = CSI 1;2 R -- ambiguous with DSR but lacks the `?` marker,
    // so it must NOT be treated as a cursor-position response.
    try std.testing.expect(parse("\x1b[1;2R") == null);
}

test "parse XTVERSION with ST terminator" {
    const r = parse("\x1bP>|xterm.js(5.5.0)\x1b\\") orelse return error.TestUnexpectedResult;
    try std.testing.expect(r == .xtversion);
    try std.testing.expectEqualStrings("xterm.js(5.5.0)", r.xtversion);
}

test "parse XTVERSION with BEL terminator" {
    const r = parse("\x1bP>|ghostty 1.2.0\x07") orelse return error.TestUnexpectedResult;
    try std.testing.expect(r == .xtversion);
    try std.testing.expectEqualStrings("ghostty 1.2.0", r.xtversion);
}

test "parse OSC response with BEL terminator" {
    const r = parse("\x1b]11;rgb:0000/0000/0000\x07") orelse return error.TestUnexpectedResult;
    try std.testing.expect(r == .osc);
    try std.testing.expectEqual(@as(u32, 11), r.osc.code);
    try std.testing.expectEqualStrings("rgb:0000/0000/0000", r.osc.data);
}

test "DCS without XTVERSION marker is not a response" {
    try std.testing.expect(parse("\x1bP1$r0m\x1b\\") == null);
}

test "XTVERSION missing terminator returns null" {
    try std.testing.expect(parse("\x1bP>|xterm.js(5.5.0)") == null);
}

test "empty and short inputs do not crash" {
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("\x1b") == null);
    try std.testing.expect(parse("\x1b[") == null);
    try std.testing.expect(parse("\x1b[?") == null);
}

test "malformed DECRPM missing dollar returns null" {
    try std.testing.expect(parse("\x1b[?2026;1y") == null);
}

test "garbage params in DA1 rejected" {
    try std.testing.expect(parse("\x1b[?1;xc") == null);
}
