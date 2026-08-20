const std = @import("std");

/// Small set of filesystem error classifiers ported from
/// claude-code-main/src/utils/errors.ts. JavaScript gets errno
/// strings ("ENOENT", "EACCES"); Zig gets tagged errors
/// (error.FileNotFound, error.AccessDenied) that the caller can
/// switch on. The point is the same: give call sites a named
/// predicate to distinguish expected "nothing here / no access"
/// outcomes from unexpected errors that should propagate.
///
/// zcode has 59 ad-hoc `error.FileNotFound => ...` catches
/// scattered across src/tools/ and src/core/. Centralising the
/// vocabulary here lets future refactors reach for isENOENT /
/// isFsInaccessible instead of reinventing the classification
/// per call site, and gives us one place to add new kernel
/// error codes as Zig's stdlib exposes them.
/// True when the error is one of the filesystem-missing /
/// unreachable codes. Matches the reference's isFsInaccessible
/// at utils/errors.ts:186 with the Zig-native error tags:
///
///   error.FileNotFound     (ENOENT: path does not exist)
///   error.AccessDenied     (EACCES: permission denied)
///   error.PermissionDenied (EPERM: operation not permitted)
///   error.NotDir           (ENOTDIR: path component not a dir)
///   error.SymLinkLoop      (ELOOP: symlink depth exceeded)
///
/// Use in catch blocks after fs operations to swallow expected
/// "nothing there / no access" cases without also swallowing
/// EIO, ENOSPC, EMFILE, etc. which should bubble up.
pub fn isFsInaccessible(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound,
        error.AccessDenied,
        error.PermissionDenied,
        error.NotDir,
        error.SymLinkLoop,
        => true,
        else => false,
    };
}

/// The most common single-error check: was this errno ENOENT?
/// Ported from the reference's isENOENT helper. Prefer this over
/// inline `err == error.FileNotFound` at call sites so the
/// vocabulary stays consistent.
pub fn isENOENT(err: anyerror) bool {
    return err == error.FileNotFound;
}

/// True when the error indicates a permission problem (EACCES
/// or EPERM). Useful for log messages that want to suggest
/// `sudo` or a file-mode fix without also firing on ENOENT.
pub fn isPermissionError(err: anyerror) bool {
    return err == error.AccessDenied or err == error.PermissionDenied;
}

const testing = std.testing;

test "isFsInaccessible flags the expected missing/no-access errors" {
    try testing.expect(isFsInaccessible(error.FileNotFound));
    try testing.expect(isFsInaccessible(error.AccessDenied));
    try testing.expect(isFsInaccessible(error.PermissionDenied));
    try testing.expect(isFsInaccessible(error.NotDir));
    try testing.expect(isFsInaccessible(error.SymLinkLoop));
}

test "isFsInaccessible returns false on unrelated errors" {
    // These should bubble up, not get swallowed.
    try testing.expect(!isFsInaccessible(error.OutOfMemory));
    try testing.expect(!isFsInaccessible(error.InvalidUtf8));
    try testing.expect(!isFsInaccessible(error.BrokenPipe));
    try testing.expect(!isFsInaccessible(error.InputOutput));
}

test "isENOENT is true only for FileNotFound" {
    try testing.expect(isENOENT(error.FileNotFound));
    try testing.expect(!isENOENT(error.AccessDenied));
    try testing.expect(!isENOENT(error.PermissionDenied));
    try testing.expect(!isENOENT(error.OutOfMemory));
}

test "isPermissionError covers both EACCES and EPERM" {
    try testing.expect(isPermissionError(error.AccessDenied));
    try testing.expect(isPermissionError(error.PermissionDenied));
    try testing.expect(!isPermissionError(error.FileNotFound));
    try testing.expect(!isPermissionError(error.OutOfMemory));
}
