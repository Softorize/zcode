//! Skill visibility filter (deep module for skill parity, PRD Softorize/zcode#532).
//!
//! Decides whether a given skill is visible to a given audience right now,
//! applying the `user-invocable`, `disable-model-invocation`, and `paths`
//! frontmatter fields parsed into `SkillSpec` (see skill_types.zig).
//!
//! PURE module: no file IO, no runtime singleton, no allocation. The predicates
//! read only the spec fields and the caller-supplied set of touched files, and
//! the glob matcher backtracks in place. This keeps the decision logic trivially
//! unit-testable in isolation.
//!
//! Existing `matchIgnoreGlob` helpers in context.zig / repl_quick_open.zig were
//! considered but rejected: they are private (not importable), encode
//! .gitignore-style semantics (directory-prefix `dir/`, extension `*.ext`,
//! exact basename) rather than general wildcards, and do not support the
//! `*` / `**` / `?` patterns this filter requires. So we carry a small matcher.

const std = @import("std");
const skill_types = @import("skill_types.zig");

pub const Audience = enum { model, user };

/// Whether `skill` is visible to `audience` given the set of files touched so
/// far this session (used for paths gating).
pub fn isVisible(
    skill: *const skill_types.SkillSpec,
    audience: Audience,
    touched_files: []const []const u8,
) bool {
    return isVisibleWithActivation(skill, audience, touched_files, &.{});
}

/// Same as `isVisible`, but a `paths`-gated skill whose name appears in
/// `activated` bypasses the per-turn paths gate (skills-04 sticky activation).
/// Once a conditional skill has matched a touched file it stays visible for the
/// rest of the session even after that file leaves `touched_files`. The audience
/// gate (`disable-model-invocation` / `user-invocable`) still applies. PURE: the
/// activated-name set is supplied by the caller so this module reads no runtime
/// state. Names are compared case-insensitively, matching `findByName`.
pub fn isVisibleWithActivation(
    skill: *const skill_types.SkillSpec,
    audience: Audience,
    touched_files: []const []const u8,
    activated: []const []const u8,
) bool {
    // 1. Audience gate.
    switch (audience) {
        .model => if (skill.disable_model_invocation) return false,
        .user => if (!skill.user_invocable) return false,
    }

    // 2. Paths gate: empty paths means no gating; otherwise a touched file must
    // match one of the globs, OR the skill has already been activated this
    // session (sticky).
    if (skill.paths.len != 0 and
        !matchesAnyPath(skill.paths, touched_files) and
        !isActivated(skill.name, activated))
    {
        return false;
    }

    // 3. Visible.
    return true;
}

/// True if `name` is in the activated set (case-insensitive). Exposed for tests.
pub fn isActivated(name: []const u8, activated: []const []const u8) bool {
    for (activated) |a| {
        if (std.ascii.eqlIgnoreCase(a, name)) return true;
    }
    return false;
}

/// True if any glob in `globs` matches any path in `touched_files`. When `globs`
/// is empty, returns true (no path gating). Exposed for testing.
pub fn matchesAnyPath(globs: []const []const u8, touched_files: []const []const u8) bool {
    if (globs.len == 0) return true;
    for (globs) |glob| {
        for (touched_files) |path| {
            if (globMatch(glob, path)) return true;
        }
    }
    return false;
}

/// Glob match for a single pattern against a single path. Exposed for testing.
///
/// Supported features:
///   - `*`  : matches any run of characters, including `/` (so `src/*` matches
///            nested paths). `**` is treated the same as `*` for simplicity.
///   - `?`  : matches exactly one character.
///   - everything else matches literally.
///
/// The pattern is tried against the FULL path first; if that fails it is also
/// tried against the basename, so a bare pattern like `*.zig` matches
/// `src/foo.zig`. Allocation-free (iterative two-pointer backtracking).
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    if (matchHere(pattern, path)) return true;

    // Fall back to matching the basename so patterns without a path separator
    // still match files nested in directories.
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        return matchHere(pattern, path[idx + 1 ..]);
    }
    return false;
}

/// Two-pointer wildcard matcher with backtracking on `*`. `*` (and `**`) match
/// any run of characters including `/`; `?` matches a single character.
fn matchHere(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0; // index into pattern
    var t: usize = 0; // index into text
    var star_p: ?usize = null; // pattern index just after the last `*`
    var star_t: usize = 0; // text index when the last `*` was taken

    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == text[t])) {
            // Literal or single-char wildcard: consume one of each.
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            // Collapse runs of `*` (handles `**`) and remember the backtrack
            // point: `*` initially matches zero characters.
            while (p < pattern.len and pattern[p] == '*') p += 1;
            star_p = p;
            star_t = t;
        } else if (star_p) |sp| {
            // Mismatch: extend the most recent `*` by one character and retry.
            p = sp;
            star_t += 1;
            t = star_t;
        } else {
            return false;
        }
    }

    // Text exhausted: any remaining pattern must be only `*`.
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Build a minimal SkillSpec for visibility tests. Only the fields read by
/// `isVisible` are meaningful; the rest are zero-length literals. `@constCast`
/// is safe here because the predicates never mutate the spec.
fn makeSpec(user_invocable: bool, disable_model_invocation: bool, paths: [][]u8) skill_types.SkillSpec {
    const empty: []u8 = @constCast("");
    const empty_list: [][]u8 = &.{};
    return .{
        .name = @constCast("test"),
        .description = empty,
        .when_to_use = empty,
        .prompt = empty,
        .scope = .builtin,
        .source_path = empty,
        .allowed_tools = empty_list,
        .arg_names = empty_list,
        .model = empty,
        .effort = empty,
        .context = .inline_skill,
        .agent = empty,
        .paths = paths,
        .user_invocable = user_invocable,
        .disable_model_invocation = disable_model_invocation,
        .version = empty,
        .aliases = empty_list,
        .hooks_json = empty,
    };
}

test "isVisible: model audience excludes disable_model_invocation" {
    const spec = makeSpec(true, true, &.{});
    try testing.expect(!isVisible(&spec, .model, &.{}));
    // ...but the user can still see it.
    try testing.expect(isVisible(&spec, .user, &.{}));
}

test "isVisible: user audience excludes !user_invocable" {
    const spec = makeSpec(false, false, &.{});
    try testing.expect(!isVisible(&spec, .user, &.{}));
    // ...the model can still see it.
    try testing.expect(isVisible(&spec, .model, &.{}));
}

test "isVisible: empty paths is always visible (no path gating)" {
    const spec = makeSpec(true, false, &.{});
    try testing.expect(isVisible(&spec, .model, &.{}));
    try testing.expect(isVisible(&spec, .user, &.{}));
    // Touched files are irrelevant when paths is empty.
    const touched = [_][]const u8{"src/foo.zig"};
    try testing.expect(isVisible(&spec, .model, &touched));
}

test "isVisible: non-empty paths visible only when a touched file matches" {
    var paths = [_][]u8{@constCast("*.zig")};
    const spec = makeSpec(true, false, &paths);

    // No files touched -> gated out.
    try testing.expect(!isVisible(&spec, .model, &.{}));

    // A non-matching file -> still gated out.
    const non_match = [_][]const u8{"docs/readme.md"};
    try testing.expect(!isVisible(&spec, .model, &non_match));

    // A matching file -> visible.
    const match = [_][]const u8{"src/core/x.zig"};
    try testing.expect(isVisible(&spec, .model, &match));
}

test "skills-04 isVisibleWithActivation: activated skill stays visible without a matching touched file" {
    var paths = [_][]u8{@constCast("*.zig")};
    const spec = makeSpec(true, false, &paths);

    // Turn 1: a matching file is touched -> visible by the paths gate.
    const match = [_][]const u8{"src/core/x.zig"};
    try testing.expect(isVisibleWithActivation(&spec, .model, &match, &.{}));

    // Turn 2: file_focus no longer matches, but the skill was activated last
    // turn (its name is in the sticky set) -> still visible.
    const activated = [_][]const u8{"test"};
    const non_match = [_][]const u8{"docs/readme.md"};
    try testing.expect(isVisibleWithActivation(&spec, .model, &non_match, &activated));

    // Without activation and without a match, it is gated out.
    try testing.expect(!isVisibleWithActivation(&spec, .model, &non_match, &.{}));
}

test "skills-04 isVisibleWithActivation: audience gate still applies to an activated skill" {
    // disable-model-invocation must still hide the skill from the model even
    // when it has been activated.
    var paths = [_][]u8{@constCast("*.zig")};
    const spec = makeSpec(true, true, &paths);
    const activated = [_][]const u8{"test"};
    try testing.expect(!isVisibleWithActivation(&spec, .model, &.{}, &activated));
    // The user can still see it (audience .user only checks user_invocable).
    try testing.expect(isVisibleWithActivation(&spec, .user, &.{}, &activated));
}

test "skills-04 isActivated: case-insensitive name membership" {
    const activated = [_][]const u8{ "Deploy", "lint" };
    try testing.expect(isActivated("deploy", &activated));
    try testing.expect(isActivated("LINT", &activated));
    try testing.expect(!isActivated("build", &activated));
    try testing.expect(!isActivated("deploy", &.{}));
}

test "matchesAnyPath: empty globs returns true" {
    const touched = [_][]const u8{"anything"};
    try testing.expect(matchesAnyPath(&.{}, &touched));
    try testing.expect(matchesAnyPath(&.{}, &.{}));
}

test "matchesAnyPath: matches across glob/path pairs" {
    const globs = [_][]const u8{ "docs/*.md", "*.zig" };
    const touched = [_][]const u8{ "README", "src/main.zig" };
    try testing.expect(matchesAnyPath(&globs, &touched));

    const no_match = [_][]const u8{ "README", "Makefile" };
    try testing.expect(!matchesAnyPath(&globs, &no_match));
}

test "globMatch: required examples" {
    try testing.expect(globMatch("*.zig", "src/core/skills.zig"));
    try testing.expect(globMatch("src/**", "src/core/x.zig"));
    try testing.expect(globMatch("docs/*.md", "docs/KAIROS.md"));
    try testing.expect(!globMatch("*.md", "src/x.zig"));
}

test "globMatch: additional wildcard cases" {
    // `*` spans `/`.
    try testing.expect(globMatch("src/*", "src/a/b/c.zig"));
    // `?` matches exactly one char.
    try testing.expect(globMatch("a?c", "abc"));
    try testing.expect(!globMatch("a?c", "ac"));
    try testing.expect(!globMatch("a?c", "abbc"));
    // `**` behaves like `*`.
    try testing.expect(globMatch("**/foo.zig", "a/b/foo.zig"));
    try testing.expect(globMatch("**", "anything/at/all"));
    // Exact literal match.
    try testing.expect(globMatch("Makefile", "Makefile"));
    try testing.expect(globMatch("Makefile", "sub/Makefile")); // basename fallback
    try testing.expect(!globMatch("Makefile", "Makefile.bak"));
    // Trailing `*` matches empty remainder.
    try testing.expect(globMatch("foo*", "foo"));
    // Bare `*` matches everything.
    try testing.expect(globMatch("*", ""));
    try testing.expect(globMatch("*", "x/y/z"));
}
