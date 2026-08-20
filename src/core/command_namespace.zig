//! Subdirectory namespacing for custom commands and skills.
//!
//! Mirrors the reference loader's `buildNamespace` / `getRegularCommandName`
//! (src/skills/loadSkillsDir.ts:533-552): the segments of a file's path that
//! sit between a root directory and the leaf are joined with `:` to form a
//! namespace prefix. A command file `root/frontend/build.md` becomes the
//! command `frontend:build`; a flat `root/build.md` becomes `build`.
//!
//! Two leaf conventions are supported because commands and skills disagree on
//! what the "leaf name" is:
//!   - commands: the file stem (`build.md` -> `build`)
//!   - skills:   the containing directory name (`deploy/SKILL.md` -> `deploy`)
//!
//! Callers thread the namespace prefix down as they recurse so this helper only
//! has to join an already-computed prefix with a leaf name.

const std = @import("std");

/// Maximum directory recursion depth for namespaced walks. Guards against
/// pathological symlink loops; the reference has no hard cap but real command
/// trees never go this deep.
pub const max_depth: usize = 8;

/// Join an already-accumulated namespace prefix (the `:`-joined chain of parent
/// directories below the root, possibly empty) with a leaf name.
///
/// `prefix == ""` -> returns a copy of `leaf` (the flat, un-namespaced case).
/// `prefix == "frontend"`, `leaf == "build"` -> `"frontend:build"`.
/// `prefix == "a:b"`, `leaf == "c"` -> `"a:b:c"`.
///
/// The returned slice is owned by the caller.
pub fn join(allocator: std.mem.Allocator, prefix: []const u8, leaf: []const u8) ![]u8 {
    if (prefix.len == 0) return allocator.dupe(u8, leaf);
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ prefix, leaf });
}

/// Extend a namespace prefix with one more directory segment as we descend into
/// a subdirectory. `parent == ""`, `segment == "frontend"` -> `"frontend"`;
/// `parent == "frontend"`, `segment == "web"` -> `"frontend:web"`.
///
/// This is identical to `join`; it exists as a named alias so recursion call
/// sites read clearly ("extend the prefix by this dir") versus the leaf join.
pub fn extend(allocator: std.mem.Allocator, parent: []const u8, segment: []const u8) ![]u8 {
    return join(allocator, parent, segment);
}

/// Strip the trailing extension from a file name (the command leaf). Returns the
/// whole name when there is no dot. `build.md` -> `build`; `noext` -> `noext`.
pub fn fileStem(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |idx| return name[0..idx];
    return name;
}

const testing = std.testing;

test "join flat name returns leaf copy" {
    const out = try join(testing.allocator, "", "build");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("build", out);
}

test "join single-segment prefix" {
    const out = try join(testing.allocator, "frontend", "build");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("frontend:build", out);
}

test "join nested prefix joins with colon" {
    const out = try join(testing.allocator, "a:b", "c");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a:b:c", out);
}

test "extend appends a directory segment" {
    const one = try extend(testing.allocator, "", "frontend");
    defer testing.allocator.free(one);
    try testing.expectEqualStrings("frontend", one);

    const two = try extend(testing.allocator, one, "web");
    defer testing.allocator.free(two);
    try testing.expectEqualStrings("frontend:web", two);
}

test "fileStem strips extension" {
    try testing.expectEqualStrings("build", fileStem("build.md"));
    try testing.expectEqualStrings("build", fileStem("build.txt"));
    try testing.expectEqualStrings("noext", fileStem("noext"));
    // Only the last dot is the split point.
    try testing.expectEqualStrings("a.b", fileStem("a.b.md"));
}
