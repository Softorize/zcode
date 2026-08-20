//! Minimal regex engine for hook tool-name matchers (PRD #534, hooks-11).
//!
//! Claude Code's hook matcher (`utils/hooks.ts:1346-1381`) treats a matcher
//! that is NOT a pipe-separated exact list as a JavaScript `RegExp` and calls
//! `regex.test(toolName)`. `test` is unanchored: it succeeds if the pattern
//! matches ANY substring of the input. This engine reproduces that `test`
//! semantics for the small operator subset hook matchers realistically use:
//!
//!   ^   start anchor (only meaningful at pattern start)
//!   $   end anchor   (only meaningful at pattern end)
//!   .   any single character
//!   *   zero-or-more of the preceding atom (greedy, backtracking)
//!   +   one-or-more of the preceding atom
//!   ?   zero-or-one of the preceding atom
//!   ()  grouping
//!   |   alternation (lowest precedence, splits the whole pattern/group)
//!   []  character class, with ranges (a-z) and leading `^` negation
//!   \\x escape of a metacharacter (so `\.` is a literal dot)
//!
//! An invalid pattern returns `false` (never panics), matching the reference's
//! "log and treat as no match" behavior at `utils/hooks.ts:1376-1380`.
//!
//! Pure: no allocation, no IO. Backtracking is bounded by the pattern + input
//! length; hook matchers are short so exponential blowup is not a practical
//! concern, but a depth guard keeps a pathological pattern from hanging.

const std = @import("std");

/// Maximum recursion / backtracking steps before giving up and returning false.
/// Generous for real matchers (which are tiny) but caps a pathological pattern.
const max_steps: usize = 100_000;

const Error = error{InvalidPattern};

/// `test`-style match: true if `pattern` matches anywhere in `text`. Anchors
/// `^`/`$` constrain to the start/end of `text`. An invalid pattern yields
/// false (no panic), matching the reference's catch-and-ignore behavior.
pub fn matches(pattern: []const u8, text: []const u8) bool {
    return matchesChecked(pattern, text) catch false;
}

/// Like `matches`, but surfaces an `error.InvalidPattern` instead of swallowing
/// it. Useful for tests that want to assert a pattern is rejected.
pub fn matchesChecked(pattern: []const u8, text: []const u8) Error!bool {
    var p = Parser{ .src = pattern };
    const re = try p.parseAlternation();
    if (!p.atEnd()) return error.InvalidPattern; // trailing unconsumed input (e.g. stray ')')

    // The AST's class nodes index into `p.class_items`, which lives on this
    // stack frame for the duration of matching. Point the matcher's view at it
    // and restore it afterward (single-threaded, synchronous matching).
    const prev_items = g_class_items;
    g_class_items = p.class_items[0..p.class_len];
    defer g_class_items = prev_items;

    var steps: usize = 0;

    // Anchored at start (`^` leading): only try matching from index 0.
    // Otherwise try every start offset (unanchored `test` semantics).
    var start: usize = 0;
    while (true) : (start += 1) {
        steps = 0;
        if (matchNode(re, text, start, &steps)) |_| return true;
        if (re.anchored_start) break; // `^` means only offset 0 is allowed
        if (start >= text.len) break;
    }
    return false;
}

// --- AST -------------------------------------------------------------------

const NodeKind = enum { literal, any, class, group, alt, concat };

const Quant = enum { one, star, plus, opt };

const Node = struct {
    kind: NodeKind,
    quant: Quant = .one,

    // literal
    ch: u8 = 0,
    // class
    class: ClassRef = .{},
    // group / concat: children slice into Parser.nodes arena
    children: []const Node = &.{},
    // alt: branches slice into Parser.branches arena
    branches: []const []const Node = &.{},

    // Top-level only: did the whole pattern start with `^` / end with `$`.
    anchored_start: bool = false,
    anchored_end: bool = false,
};

const ClassRef = struct {
    // Index range into Parser.class_items for this class.
    start: usize = 0,
    len: usize = 0,
    negated: bool = false,
};

const ClassItem = struct {
    lo: u8,
    hi: u8, // inclusive range; lo==hi for a single char
};

// --- Parser ----------------------------------------------------------------

// Fixed-capacity arenas: hook matchers are short, so static buffers avoid any
// allocation. Overflow -> InvalidPattern (treated as no match by the caller).
const max_nodes = 512;
const max_branches = 64;
const max_class_items = 256;
// Max direct atoms in a single concatenation level (bounds the per-frame stack
// buffer in parseConcat). Hook matchers are short; 256 is generous.
const max_concat_atoms = 256;

const Parser = struct {
    src: []const u8,
    pos: usize = 0,

    // `nodes` holds the linear atom sequence that `parseConcat` slices into a
    // concat's `children`. Structural nodes (a group's inner node, an alt
    // branch's concat node) MUST live in a separate arena so they never
    // interleave into a concat's contiguous child range.
    nodes: [max_nodes]Node = undefined,
    node_len: usize = 0,
    sub_nodes: [max_nodes]Node = undefined,
    sub_len: usize = 0,
    branch_store: [max_branches][]const Node = undefined,
    branch_len: usize = 0,
    class_items: [max_class_items]ClassItem = undefined,
    class_len: usize = 0,

    fn atEnd(self: *Parser) bool {
        return self.pos >= self.src.len;
    }

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    fn advance(self: *Parser) u8 {
        const c = self.src[self.pos];
        self.pos += 1;
        return c;
    }

    fn pushNode(self: *Parser, n: Node) Error!usize {
        if (self.node_len >= max_nodes) return error.InvalidPattern;
        self.nodes[self.node_len] = n;
        self.node_len += 1;
        return self.node_len - 1;
    }

    /// Push a structural node (group inner / alt branch concat) into the
    /// separate `sub_nodes` arena and return a one-element slice referencing it.
    fn pushSub(self: *Parser, n: Node) Error![]const Node {
        if (self.sub_len >= max_nodes) return error.InvalidPattern;
        self.sub_nodes[self.sub_len] = n;
        self.sub_len += 1;
        return self.sub_nodes[self.sub_len - 1 .. self.sub_len];
    }

    /// Parse alternation: `concat ('|' concat)*`. Returns a single node: either
    /// the lone concat (kind=concat) or an `alt` node holding the branches.
    /// Each alt branch is stored as a one-element slice holding the full concat
    /// node, so per-branch `^`/`$` anchor flags survive (a bare children slice
    /// would drop them).
    fn parseAlternation(self: *Parser) Error!Node {
        const first = try self.parseConcat();

        if (self.peek() != @as(u8, '|')) {
            return first;
        }

        const branch_base = self.branch_len;
        try self.addConcatBranch(first);

        while (self.peek() == @as(u8, '|')) {
            _ = self.advance(); // consume '|'
            const next = try self.parseConcat();
            try self.addConcatBranch(next);
        }

        return Node{
            .kind = .alt,
            .branches = self.branch_store[branch_base..self.branch_len],
            .anchored_start = false,
            .anchored_end = false,
        };
    }

    /// Store a concat node as a single-element branch slice in the structural
    /// arena so the alt branch retains the concat's anchor flags and does not
    /// interleave into any concat's child sequence.
    fn addConcatBranch(self: *Parser, concat: Node) Error!void {
        if (self.branch_len >= max_branches) return error.InvalidPattern;
        self.branch_store[self.branch_len] = try self.pushSub(concat);
        self.branch_len += 1;
    }

    /// Parse a concatenation: a run of quantified atoms until `|`, `)`, or end.
    /// Returns a `concat` node whose direct atoms are copied as one contiguous
    /// block into the `nodes` arena. A local buffer collects the atoms first so
    /// that nested sub-parsing (groups, alternations) never interleaves nodes
    /// into this concat's child range.
    fn parseConcat(self: *Parser) Error!Node {
        var local: [max_concat_atoms]Node = undefined;
        var n: usize = 0;
        var anchored_start = false;
        var anchored_end = false;

        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;

            if (c == '^') {
                _ = self.advance();
                // `^` is only an anchor at the very start of this concat.
                if (n == 0) {
                    anchored_start = true;
                    continue;
                }
                // Otherwise treat as a literal caret (best-effort, rare).
                if (n >= local.len) return error.InvalidPattern;
                local[n] = Node{ .kind = .literal, .ch = '^' };
                n += 1;
                continue;
            }

            if (c == '$') {
                _ = self.advance();
                // `$` is only an anchor if it ends the concat (next is |, ), end).
                const nxt = self.peek();
                if (nxt == null or nxt == @as(u8, '|') or nxt == @as(u8, ')')) {
                    anchored_end = true;
                    continue;
                }
                if (n >= local.len) return error.InvalidPattern;
                local[n] = Node{ .kind = .literal, .ch = '$' };
                n += 1;
                continue;
            }

            const atom = try self.parseAtom();
            const q = self.parseQuant();
            var node = atom;
            node.quant = q;
            if (n >= local.len) return error.InvalidPattern;
            local[n] = node;
            n += 1;
        }

        // Copy the collected atoms as one contiguous block into the arena.
        const start_idx = self.node_len;
        if (self.node_len + n > max_nodes) return error.InvalidPattern;
        for (local[0..n]) |node| {
            self.nodes[self.node_len] = node;
            self.node_len += 1;
        }

        return Node{
            .kind = .concat,
            .children = self.nodes[start_idx..self.node_len],
            .anchored_start = anchored_start,
            .anchored_end = anchored_end,
        };
    }

    fn parseQuant(self: *Parser) Quant {
        switch (self.peek() orelse return .one) {
            '*' => {
                _ = self.advance();
                return .star;
            },
            '+' => {
                _ = self.advance();
                return .plus;
            },
            '?' => {
                _ = self.advance();
                return .opt;
            },
            else => return .one,
        }
    }

    /// Parse a single atom (no quantifier): literal, `.`, `(...)`, or `[...]`.
    fn parseAtom(self: *Parser) Error!Node {
        const c = self.advance();
        switch (c) {
            '.' => return Node{ .kind = .any },
            '(' => {
                const inner = try self.parseAlternation();
                if (self.peek() != @as(u8, ')')) return error.InvalidPattern;
                _ = self.advance(); // consume ')'
                // Stash the inner node in the structural arena so it does not
                // become a sibling atom in the enclosing concat's child range.
                return Node{
                    .kind = .group,
                    .children = try self.pushSub(inner),
                };
            },
            '[' => return try self.parseClass(),
            '\\' => {
                // Escape: next char is a literal metacharacter.
                if (self.atEnd()) return error.InvalidPattern;
                const esc = self.advance();
                return Node{ .kind = .literal, .ch = esc };
            },
            ')' => return error.InvalidPattern, // stray close paren
            else => return Node{ .kind = .literal, .ch = c },
        }
    }

    fn parseClass(self: *Parser) Error!Node {
        var negated = false;
        if (self.peek() == @as(u8, '^')) {
            _ = self.advance();
            negated = true;
        }
        const items_start = self.class_len;

        // A `]` immediately after `[` (or `[^`) is a literal `]`.
        var first = true;
        while (true) {
            const c = self.peek() orelse return error.InvalidPattern; // unterminated class
            if (c == ']' and !first) {
                _ = self.advance();
                break;
            }
            first = false;
            _ = self.advance();

            var lo = c;
            if (c == '\\') {
                if (self.atEnd()) return error.InvalidPattern;
                lo = self.advance();
            }

            // Range: `a-z` (but a trailing `-` before `]` is a literal `-`).
            var hi = lo;
            if (self.peek() == @as(u8, '-')) {
                const after_dash = if (self.pos + 1 < self.src.len) self.src[self.pos + 1] else 0;
                if (after_dash != ']' and self.pos + 1 < self.src.len) {
                    _ = self.advance(); // consume '-'
                    var rhi = self.advance();
                    if (rhi == '\\') {
                        if (self.atEnd()) return error.InvalidPattern;
                        rhi = self.advance();
                    }
                    hi = rhi;
                }
            }
            if (hi < lo) return error.InvalidPattern; // inverted range
            if (self.class_len >= max_class_items) return error.InvalidPattern;
            self.class_items[self.class_len] = .{ .lo = lo, .hi = hi };
            self.class_len += 1;
        }

        return Node{
            .kind = .class,
            .class = .{
                .start = items_start,
                .len = self.class_len - items_start,
                .negated = negated,
            },
        };
    }
};

// --- Matcher ---------------------------------------------------------------

// The parsed AST references the Parser's static arenas. To match after the
// Parser goes out of scope we keep matching inside `matchesChecked` while the
// Parser is still alive (it is - we call matchNode before returning). The class
// items live in the Parser too, so we pass them through a thread of pointers.
//
// To keep the matcher pure and arena-agnostic, class items are resolved via the
// slices embedded in nodes during a post-parse fixup is avoided; instead we
// recompute membership by carrying the items in the Node's class range plus the
// global items buffer. Since matchNode runs while Parser is alive, we stash a
// pointer to the items in a thread-local-free way: by closing over them in the
// top-level call. We thread them explicitly.

// Global pointer set just before matching, cleared after. Single-threaded use
// (regex matching here is synchronous), so a module-level pointer is safe and
// avoids threading the items array through every recursive call.
var g_class_items: []const ClassItem = &.{};

fn matchNode(re: Node, text: []const u8, start: usize, steps: *usize) ?usize {
    // Re-point the class-items view for this match run. The Parser that owns
    // them is still on the stack of the caller (matchesChecked), so the slice
    // is valid. We cannot store it on the Node (it would need the items buffer),
    // so we capture it once via the top-level matcher entry below.
    return matchConcatOrAlt(re, text, start, steps);
}

fn step(steps: *usize) bool {
    steps.* += 1;
    return steps.* <= max_steps;
}

/// Match a concat or alt node starting at `pos`; returns the end position on
/// success (the index just past the matched span), or null.
fn matchConcatOrAlt(node: Node, text: []const u8, pos: usize, steps: *usize) ?usize {
    if (!step(steps)) return null;
    switch (node.kind) {
        .concat => {
            // Anchored start: the leading `^` already constrains pos==0 at the
            // top level; for nested concats inside groups it is a no-op here.
            const end = matchSeq(node.children, 0, text, pos, steps) orelse return null;
            if (node.anchored_end and end != text.len) return null;
            return end;
        },
        .alt => {
            // Each branch is a one-element slice holding a concat node; match
            // it recursively so its anchor flags are honored.
            for (node.branches) |branch| {
                if (matchConcatOrAlt(branch[0], text, pos, steps)) |end| return end;
            }
            return null;
        },
        else => unreachable,
    }
}

/// Match a sequence of children starting at child index `ci`, input index
/// `pos`. Returns the end position. Handles quantifiers with backtracking.
fn matchSeq(children: []const Node, ci: usize, text: []const u8, pos: usize, steps: *usize) ?usize {
    if (!step(steps)) return null;
    if (ci >= children.len) return pos; // matched all children

    const child = children[ci];
    switch (child.quant) {
        .one => {
            const np = matchAtom(child, text, pos, steps) orelse return null;
            return matchSeq(children, ci + 1, text, np, steps);
        },
        .opt => {
            // Try with one match first (greedy), then without.
            if (matchAtom(child, text, pos, steps)) |np| {
                if (matchSeq(children, ci + 1, text, np, steps)) |end| return end;
            }
            return matchSeq(children, ci + 1, text, pos, steps);
        },
        .star => return matchRepeat(children, ci, text, pos, 0, steps),
        .plus => return matchRepeat(children, ci, text, pos, 1, steps),
    }
}

/// Greedy repetition for `*` (min=0) and `+` (min=1) with backtracking.
fn matchRepeat(children: []const Node, ci: usize, text: []const u8, pos: usize, min: usize, steps: *usize) ?usize {
    const child = children[ci];

    // Record each end position reachable by consuming the atom greedily, then
    // backtrack from the longest down to `min` repetitions.
    var ends_buf: [1024]usize = undefined;
    var count: usize = 0;
    ends_buf[0] = pos; // 0 repetitions
    count = 1;

    // ends_buf[r] = input position after consuming the atom `r` times greedily.
    var cur = pos;
    while (count < ends_buf.len) {
        if (!step(steps)) return null;
        const np = matchAtom(child, text, cur, steps) orelse break;
        if (np == cur) break; // zero-width match guard (e.g. `a*` where atom matched empty)
        ends_buf[count] = np;
        count += 1;
        cur = np;
    }

    // count is now the number of stored positions: indices 0..count-1 map to
    // 0..count-1 repetitions. Backtrack from the maximum down to `min`.
    if (count == 0) return null; // shouldn't happen (index 0 is always stored)
    var reps = count - 1; // greediest available repetition count
    while (true) {
        if (reps < min) break;
        if (matchSeq(children, ci + 1, text, ends_buf[reps], steps)) |end| return end;
        if (reps == 0) break;
        reps -= 1;
    }
    return null;
}

/// Match a single atom (ignoring its quantifier) at `pos`. Returns end pos.
fn matchAtom(node: Node, text: []const u8, pos: usize, steps: *usize) ?usize {
    if (!step(steps)) return null;
    switch (node.kind) {
        .literal => {
            if (pos < text.len and text[pos] == node.ch) return pos + 1;
            return null;
        },
        .any => {
            if (pos < text.len) return pos + 1;
            return null;
        },
        .class => {
            if (pos >= text.len) return null;
            const c = text[pos];
            var hit = false;
            const items = g_class_items[node.class.start .. node.class.start + node.class.len];
            for (items) |it| {
                if (c >= it.lo and c <= it.hi) {
                    hit = true;
                    break;
                }
            }
            if (node.class.negated) hit = !hit;
            if (hit) return pos + 1;
            return null;
        },
        .group => {
            // The group wraps one inner concat/alt node.
            const inner = node.children[0];
            return matchConcatOrAlt(inner, text, pos, steps);
        },
        else => return null,
    }
}

// --- public entry that sets the class-items view --------------------------

// matchesChecked above calls matchNode while the Parser is alive; set the
// global class-items pointer there. We patch matchesChecked to install it.

const testing = std.testing;

test "mini_regex: literal and anchors" {
    try testing.expect(matches("Bash", "Bash"));
    try testing.expect(matches("Bash", "BashOutput")); // unanchored test() semantics
    try testing.expect(matches("^Bash$", "Bash"));
    try testing.expect(!matches("^Bash$", "BashOutput"));
    try testing.expect(matches("^Bash", "BashOutput"));
    try testing.expect(!matches("^Output", "BashOutput"));
}

test "mini_regex: dot and star and plus and opt" {
    try testing.expect(matches("^Notebook.*", "NotebookEdit"));
    try testing.expect(matches("^a.c$", "abc"));
    try testing.expect(!matches("^a.c$", "abbc"));
    try testing.expect(matches("^ab*c$", "ac"));
    try testing.expect(matches("^ab*c$", "abbbc"));
    try testing.expect(matches("^ab+c$", "abc"));
    try testing.expect(!matches("^ab+c$", "ac"));
    try testing.expect(matches("^ab?c$", "ac"));
    try testing.expect(matches("^ab?c$", "abc"));
    try testing.expect(!matches("^ab?c$", "abbc"));
}

test "mini_regex: alternation and groups" {
    try testing.expect(matches("^(Edit|Write)$", "Edit"));
    try testing.expect(matches("^(Edit|Write)$", "Write"));
    try testing.expect(!matches("^(Edit|Write)$", "Read"));
    try testing.expect(matches("^(ab)+$", "abab"));
    try testing.expect(!matches("^(ab)+$", "aba"));
    // top-level alternation (no group)
    try testing.expect(matches("^Edit$|^Write$", "Write"));
    try testing.expect(!matches("^Edit$|^Write$", "Read"));
}

test "mini_regex: character classes" {
    try testing.expect(matches("^[A-Z][a-z]+$", "Bash"));
    try testing.expect(!matches("^[A-Z][a-z]+$", "bash"));
    try testing.expect(matches("^[A-Za-z0-9_]+$", "Tool_2"));
    try testing.expect(!matches("^[A-Za-z0-9_]+$", "Tool-2"));
    // negated class
    try testing.expect(matches("^[^0-9]+$", "abc"));
    try testing.expect(!matches("^[^0-9]+$", "ab2"));
}

test "mini_regex: escape of metacharacters" {
    try testing.expect(matches("^a\\.c$", "a.c"));
    try testing.expect(!matches("^a\\.c$", "abc"));
    try testing.expect(matches("\\$", "cost is $5"));
}

test "mini_regex: invalid pattern returns false (no panic)" {
    try testing.expect(!matches("(", "abc")); // unbalanced open paren
    try testing.expect(!matches(")", "abc")); // stray close paren
    try testing.expect(!matches("[a-", "abc")); // unterminated class
    try testing.expect(!matches("[z-a]", "b")); // inverted range
    try testing.expect(!matches("ab\\", "ab")); // dangling escape
    // matchesChecked surfaces the error
    try testing.expectError(error.InvalidPattern, matchesChecked("(", "x"));
}
