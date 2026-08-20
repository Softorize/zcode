//! Centralised stdio writers/readers. After the Zig 0.16 migration the
//! old `std.Io.File.DeprecatedWriter` shim is gone, so this module
//! re-exposes a tiny print/writeAll/writeByte API on top of
//! `std.Io.File.stderr/stdout/stdin` + `writeStreamingAll`.
//!
//! Every call site can keep using:
//!
//!     try std_io.stderrWriter().print(fmt, args);
//!     try std_io.stdoutWriter().writeAll(bytes);
//!
//! The returned facade is zero-size and rebuilds a per-call buffer for
//! formatted prints. Fine for diagnostic prints; heavy throughput
//! callers should obtain a buffered `std.Io.File.Writer` directly.
//!
//! Stage 4 of the migration retires the rt.io singleton; this file
//! will then take io explicitly instead of pulling it from runtime.

const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");

const print_buf_size: usize = 4096;

fn writeAllTo(file: std.Io.File, bytes: []const u8) !void {
    try file.writeStreamingAll(rt.io, bytes);
}

fn printTo(file: std.Io.File, comptime fmt: []const u8, args: anytype) !void {
    var buf: [print_buf_size]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print(fmt, args);
    try file.writeStreamingAll(rt.io, w.buffered());
}

pub const StderrWriter = struct {
    pub fn print(self: StderrWriter, comptime fmt: []const u8, args: anytype) !void {
        _ = self;
        try printTo(std.Io.File.stderr(), fmt, args);
    }
    pub fn writeAll(self: StderrWriter, bytes: []const u8) !void {
        _ = self;
        try writeAllTo(std.Io.File.stderr(), bytes);
    }
    pub fn writeByte(self: StderrWriter, b: u8) !void {
        try self.writeAll(&.{b});
    }
    pub fn write(self: StderrWriter, bytes: []const u8) !usize {
        try self.writeAll(bytes);
        return bytes.len;
    }
    pub fn splatByteAll(self: StderrWriter, b: u8, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) try self.writeByte(b);
    }
};

pub const StdoutWriter = struct {
    pub fn print(self: StdoutWriter, comptime fmt: []const u8, args: anytype) !void {
        _ = self;
        try printTo(std.Io.File.stdout(), fmt, args);
    }
    pub fn writeAll(self: StdoutWriter, bytes: []const u8) !void {
        _ = self;
        try writeAllTo(std.Io.File.stdout(), bytes);
    }
    pub fn writeByte(self: StdoutWriter, b: u8) !void {
        try self.writeAll(&.{b});
    }
    pub fn write(self: StdoutWriter, bytes: []const u8) !usize {
        try self.writeAll(bytes);
        return bytes.len;
    }
    pub fn splatByteAll(self: StdoutWriter, b: u8, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) try self.writeByte(b);
    }
};

pub const FileWriter = struct {
    file: std.Io.File,

    pub fn print(self: FileWriter, comptime fmt: []const u8, args: anytype) !void {
        try printTo(self.file, fmt, args);
    }
    pub fn writeAll(self: FileWriter, bytes: []const u8) !void {
        try writeAllTo(self.file, bytes);
    }
    pub fn writeByte(self: FileWriter, b: u8) !void {
        try self.writeAll(&.{b});
    }
    pub fn write(self: FileWriter, bytes: []const u8) !usize {
        try self.writeAll(bytes);
        return bytes.len;
    }
};

pub const StdinReader = struct {
    /// Reads up to dst.len bytes from stdin. Returns the number read; 0 on EOF.
    /// stdin is a pipe in most invocations, so use readStreaming which is the
    /// pread-free primitive that doesn't ESPIPE on pipes.
    pub fn read(self: StdinReader, dst: []u8) !usize {
        _ = self;
        return std.Io.File.stdin().readStreaming(rt.io, &.{dst});
    }
    pub fn readByte(self: StdinReader) !u8 {
        var b: [1]u8 = undefined;
        const n = try self.read(&b);
        if (n == 0) return error.EndOfStream;
        return b[0];
    }
    pub fn readUntilDelimiterOrEofAlloc(self: StdinReader, allocator: std.mem.Allocator, delim: u8, max: usize) !?[]u8 {
        _ = self;
        var buf = StringBuilder.init(allocator);
        errdefer buf.deinit();
        var count: usize = 0;
        while (count < max) : (count += 1) {
            var b: [1]u8 = undefined;
            const n = std.Io.File.stdin().readStreaming(rt.io, &.{&b}) catch {
                if (buf.items().len == 0) return null;
                return try buf.toOwnedSlice();
            };
            if (n == 0) {
                if (buf.items().len == 0) return null;
                return try buf.toOwnedSlice();
            }
            if (b[0] == delim) return try buf.toOwnedSlice();
            try buf.append(b[0]);
        }
        return error.StreamTooLong;
    }
};

pub const FileReader = struct {
    file: std.Io.File,
    offset: u64 = 0,

    /// Streaming read against an internal offset. Each call advances
    /// `offset` by the number of bytes returned, so callers can loop
    /// without managing the offset themselves.
    pub fn read(self: *FileReader, dst: []u8) !usize {
        const n = try self.file.readPositionalAll(rt.io, dst, self.offset);
        self.offset += n;
        return n;
    }
};

/// Drop-in compatibility shim for Zig 0.15's
/// `std_io.StringBuilder` which is gone in 0.16. Wraps the new
/// `std.Io.Writer.Allocating` so existing call sites keep working with
/// minimal edits.
///
/// Old pattern (0.15):
///     var buf = std_io.StringBuilder.init(allocator);
///     defer buf.deinit();
///     const w = buf.writer();
///     try w.print(...);
///     return buf.toOwnedSlice();
///
/// New pattern (0.16, via this shim):
///     var buf = std_io.StringBuilder.init(allocator);
///     defer buf.deinit();
///     const w = buf.writer();
///     try w.print(...);
///     return buf.toOwnedSlice();
pub const StringBuilder = struct {
    allocator: std.mem.Allocator,
    inner: std.Io.Writer.Allocating,

    pub fn init(allocator: std.mem.Allocator) StringBuilder {
        return .{
            .allocator = allocator,
            .inner = std.Io.Writer.Allocating.init(allocator),
        };
    }

    pub fn deinit(self: *StringBuilder) void {
        self.inner.deinit();
    }

    pub fn writer(self: *StringBuilder) *std.Io.Writer {
        return &self.inner.writer;
    }

    pub fn items(self: *const StringBuilder) []u8 {
        return self.inner.writer.buffered();
    }

    pub fn append(self: *StringBuilder, item: u8) !void {
        try self.inner.writer.writeByte(item);
    }

    pub fn appendSlice(self: *StringBuilder, bytes: []const u8) !void {
        try self.inner.writer.writeAll(bytes);
    }

    pub fn appendNTimes(self: *StringBuilder, b: u8, n: usize) !void {
        try self.inner.writer.splatByteAll(b, n);
    }

    pub fn ensureTotalCapacity(self: *StringBuilder, new_capacity: usize) !void {
        try self.inner.ensureTotalCapacity(new_capacity);
    }

    pub fn ensureUnusedCapacity(self: *StringBuilder, additional: usize) !void {
        try self.inner.ensureUnusedCapacity(additional);
    }

    pub fn clearRetainingCapacity(self: *StringBuilder) void {
        self.inner.writer.end = 0;
    }

    pub fn clearAndFree(self: *StringBuilder) void {
        self.inner.deinit();
        self.inner = std.Io.Writer.Allocating.init(self.allocator);
    }

    pub fn shrinkRetainingCapacity(self: *StringBuilder, new_len: usize) void {
        if (new_len < self.inner.writer.end) self.inner.writer.end = new_len;
    }

    pub fn pop(self: *StringBuilder) ?u8 {
        if (self.inner.writer.end == 0) return null;
        self.inner.writer.end -= 1;
        return self.inner.writer.buffer[self.inner.writer.end];
    }

    pub fn insertSlice(self: *StringBuilder, idx: usize, slice: []const u8) !void {
        try self.inner.ensureUnusedCapacity(slice.len);
        const end = self.inner.writer.end;
        if (idx > end) return error.InvalidIndex;
        std.mem.copyBackwards(u8, self.inner.writer.buffer[idx + slice.len .. end + slice.len], self.inner.writer.buffer[idx..end]);
        @memcpy(self.inner.writer.buffer[idx..][0..slice.len], slice);
        self.inner.writer.end += slice.len;
    }

    pub fn insert(self: *StringBuilder, idx: usize, b: u8) !void {
        try self.insertSlice(idx, &.{b});
    }

    pub fn orderedRemove(self: *StringBuilder, idx: usize) u8 {
        const end = self.inner.writer.end;
        if (idx >= end) return 0;
        const removed = self.inner.writer.buffer[idx];
        std.mem.copyForwards(u8, self.inner.writer.buffer[idx .. end - 1], self.inner.writer.buffer[idx + 1 .. end]);
        self.inner.writer.end -= 1;
        return removed;
    }

    pub fn replaceRange(self: *StringBuilder, start: usize, len: usize, with: []const u8) !void {
        const end = start + len;
        const cur_end = self.inner.writer.end;
        if (with.len == len) {
            @memcpy(self.inner.writer.buffer[start..end], with);
        } else if (with.len < len) {
            @memcpy(self.inner.writer.buffer[start..][0..with.len], with);
            std.mem.copyForwards(u8, self.inner.writer.buffer[start + with.len .. cur_end - (len - with.len)], self.inner.writer.buffer[end..cur_end]);
            self.inner.writer.end = cur_end - (len - with.len);
        } else {
            try self.inner.ensureUnusedCapacity(with.len - len);
            std.mem.copyBackwards(u8, self.inner.writer.buffer[start + with.len .. cur_end + (with.len - len)], self.inner.writer.buffer[end..cur_end]);
            @memcpy(self.inner.writer.buffer[start..][0..with.len], with);
            self.inner.writer.end = cur_end + (with.len - len);
        }
    }

    pub fn toOwnedSlice(self: *StringBuilder) ![]u8 {
        var list = self.inner.toArrayList();
        return list.toOwnedSlice(self.allocator);
    }
};

pub fn stderrWriter() StderrWriter {
    return .{};
}

pub fn stdoutWriter() StdoutWriter {
    return .{};
}

pub fn stdinReader() StdinReader {
    return .{};
}

pub fn fileWriter(file: std.Io.File) FileWriter {
    return .{ .file = file };
}

pub fn fileReader(file: std.Io.File) FileReader {
    return .{ .file = file };
}

/// Compatibility shim: write to std.Io.net.Stream as if it had writeAll.
/// 0.16 stripped writeAll from Stream; callers go through this instead.
pub fn streamWriteAll(stream: std.Io.net.Stream, bytes: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = stream.writer(rt.io, &buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

/// Read from std.Io.net.Stream into dst.
pub fn streamRead(stream: std.Io.net.Stream, dst: []u8) !usize {
    var buf: [4096]u8 = undefined;
    var r = stream.reader(rt.io, &buf);
    return r.interface.readSliceShort(dst);
}

/// Compatibility: open a file path with libc open(). Used where the
/// original code reached for std.posix.open with specific O_* flags.
/// Caller passes a NUL-terminated path; the buffer must outlive this call.
pub fn openFlags(path_z: [*:0]const u8, flags: std.posix.O, mode: u16) !std.posix.fd_t {
    const fd = std.c.open(path_z, @bitCast(flags), mode);
    if (fd < 0) return error.OpenFailed;
    return fd;
}

pub fn openFlagsAlloc(allocator: std.mem.Allocator, path: []const u8, flags: std.posix.O, mode: u16) !std.posix.fd_t {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    return openFlags(path_z.ptr, flags, mode);
}

/// streamUntilDelimiter shim: read from stdin into a writer until a delimiter byte.
pub fn streamUntilDelimiter(w: *std.Io.Writer, delim: u8, max: usize) !void {
    var count: usize = 0;
    while (count < max) : (count += 1) {
        var b: [1]u8 = undefined;
        const n = std.Io.File.stdin().readPositionalAll(rt.io, &b, 0) catch return error.EndOfStream;
        if (n == 0) return error.EndOfStream;
        if (b[0] == delim) return;
        try w.writeByte(b[0]);
    }
    return error.StreamTooLong;
}

/// Read from stdin until delim or EOF; allocates the line.
pub fn readUntilDelimiterOrEofAlloc(_: StdinReader, allocator: std.mem.Allocator, delim: u8, max: usize) !?[]u8 {
    var buf = StringBuilder.init(allocator);
    errdefer buf.deinit();
    var count: usize = 0;
    while (count < max) : (count += 1) {
        var b: [1]u8 = undefined;
        const n = std.Io.File.stdin().readPositionalAll(rt.io, &b, 0) catch {
            if (buf.items().len == 0) return null;
            return try buf.toOwnedSlice();
        };
        if (n == 0) {
            if (buf.items().len == 0) return null;
            return try buf.toOwnedSlice();
        }
        if (b[0] == delim) return try buf.toOwnedSlice();
        try buf.append(b[0]);
    }
    return error.StreamTooLong;
}
