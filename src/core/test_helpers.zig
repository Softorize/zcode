//! Test-only helpers introduced during the Zig 0.16 migration.
//!
//! `tmpDirCwd` returns an absolute path string for the realpath of "."
//! inside a `std.testing.TmpDir`. Tests in this repo pass `cwd: []const u8`
//! into tool entry points, so they need an absolute, allocator-owned slice.

const std = @import("std");
const rt = @import("zcode_runtime");

pub fn tmpDirCwd(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(rt.io, &buf);
    return allocator.dupe(u8, buf[0..n]);
}

/// Resolve a sub-path inside the tmp dir to an absolute realpath.
/// Replacement for the 0.15 `tmp.dir.realpathAlloc` helper that
/// 0.16 removed.
pub fn tmpDirPath(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    sub_path: []const u8,
) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(rt.io, sub_path, &buf);
    return allocator.dupe(u8, buf[0..n]);
}
