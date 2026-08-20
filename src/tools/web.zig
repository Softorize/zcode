const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("../core/std_io.zig");
const helpers = @import("helpers.zig");
const http_common = @import("../providers/common.zig");
const egress = @import("../core/egress.zig");
const html_to_text = @import("../core/html_to_text.zig");
const web_preapproved = @import("../core/web_preapproved.zig");
const web_summarize = @import("web_summarize.zig");
const url_host = @import("../core/url_host.zig");
const web_artifacts = @import("../core/web_artifacts.zig");
const ssrf_guard = @import("../core/ssrf_guard.zig");

/// Optional secondary-summarization context threaded from the dispatch layer.
/// When present alongside a non-null `prompt`, the post-fetch step may run the
/// page content through a small/fast model that answers the prompt. Null at
/// call sites that have no model-call plumbing (tests, headless paths) -- in
/// that case the fetch behaves exactly as before (raw stripped content).
pub const FetchContext = web_summarize.SummarizeContext;

/// Result of the network-free post-fetch decision: either return the stripped
/// content as-is, or run it through the secondary summarization model.
pub const PostFetchDecision = enum { raw, summarize };

/// Pure decision: given the caller's optional `prompt`, the fetched `url`, and
/// the already-stripped `content`, decide whether to return the content raw or
/// route it through the secondary-model summarization pass.
///
/// Mirrors the reference (WebFetchTool.ts:264-278): content is returned raw only
/// when there is no prompt, OR when the host is preapproved AND the content
/// looks like markdown/plain text AND it is under MAX_MARKDOWN_LENGTH. Everything
/// else with a prompt goes through the model pass. Pure -- unit-testable without
/// a network or model call.
pub fn decideWebFetchResult(prompt: ?[]const u8, url: []const u8, content: []const u8) PostFetchDecision {
    if (prompt == null) return .raw;
    const looks_textual = !bodyLooksLikeHtml(content);
    if (web_preapproved.isPreapprovedUrl(url) and
        looks_textual and
        content.len < web_summarize.MAX_MARKDOWN_LENGTH)
    {
        return .raw;
    }
    return .summarize;
}

/// Cheap heuristic: decide whether a response body is HTML that should
/// be cleaned up before returning to the model. We don't get a
/// Content-Type header back from the curl pipeline (our status
/// marker trick only captures the HTTP status), so we sniff the
/// first 512 bytes instead.
///
/// A body qualifies as HTML when it starts with (after trimming
/// whitespace) `<!DOCTYPE`, `<html`, `<HTML`, `<body`, or any of
/// the common block-opening tags (`<div`, `<p`, `<section`,
/// `<article`, `<main`, `<h1`..`<h6`). JSON responses open with
/// `{` or `[` and fall through unchanged. Plain text and code
/// snippets also fall through.
fn bodyLooksLikeHtml(body: []const u8) bool {
    const head_len = @min(body.len, 512);
    const head = std.mem.trimStart(u8, body[0..head_len], " \t\r\n\xef\xbb\xbf");
    if (head.len == 0) return false;

    const markers = [_][]const u8{
        "<!DOCTYPE", "<!doctype", "<html", "<HTML", "<body",    "<BODY",
        "<head",     "<HEAD",     "<div",  "<DIV",  "<section", "<SECTION",
        "<article",  "<ARTICLE",  "<main", "<MAIN", "<nav",     "<NAV",
        "<header",   "<HEADER",   "<p>",   "<P>",   "<h1",      "<H1",
        "<h2",       "<H2",
    };
    for (markers) |m| {
        if (std.mem.startsWith(u8, head, m)) return true;
    }
    return false;
}

pub fn webFetch(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    url: []const u8,
    max_bytes: usize,
    prompt: ?[]const u8,
    fetch_ctx: ?FetchContext,
) ![]u8 {
    // Route through the central egress chokepoint (core/egress.zig).
    // This unifies the scheme + SSRF + (future) allowlist policy
    // across web fetch / providers / MCP transports. Replaces the
    // previous ad-hoc check that allowed plaintext http:// to ANY
    // host -- the central policy permits http:// only for loopback
    // (127.0.0.1 / localhost / [::1]), which is the right fit for
    // local Ollama / dev policy servers. https:// is required for
    // every public host so a network observer cannot snoop the
    // response body.
    switch (egress.checkUrl(allocator, url, .{})) {
        .allow => {},
        .deny_scheme => return allocator.dupe(u8, "web fetch failed: URL must use https:// (or http:// to a loopback address). Plaintext HTTP to remote hosts is blocked so a network observer cannot read the response body."),
        .deny_ssrf => return allocator.dupe(u8, "web fetch failed: URL resolves to a blocked address (cloud metadata endpoint, link-local, or private IP range). This is an SSRF defense -- legitimate public URLs pass through."),
        .deny_allowlist => return allocator.dupe(u8, "web fetch failed: host is not in the managed-config egress allowlist."),
        .deny_denylist => return allocator.dupe(u8, "web fetch failed: host is on the managed-config egress deny list."),
    }
    const status_marker = "\n__ZCODE_WEB_STATUS__:";
    // The --write-out marker carries three trailing fields after the body,
    // each on its own sub-marker line so a Content-Type value (which can
    // itself contain spaces and a `; charset=...` parameter) cannot collide
    // with the field separator:
    //   status_marker  + %{http_code}     -- plain digits
    //   ctype_marker   + %{content_type}  -- e.g. "application/pdf" or
    //                                        "text/html; charset=utf-8"
    //   url_marker     + %{url_effective} -- the final URL after redirects
    // The body is everything before the LAST status_marker occurrence; the
    // ctype and url markers are parsed from the trailer that follows it. We
    // parse from the LAST status_marker (lastIndexOf) so body bytes that
    // happen to contain the marker text don't confuse the split.
    const ctype_marker = "\n__ZCODE_WEB_CTYPE__:";
    const url_marker = "\n__ZCODE_WEB_URL__:";
    const argv = [_][]const u8{
        "curl",
        "-L",
        // Restrict the initial request and any redirect targets to http/https
        // so that a legitimate https:// URL cannot 3xx-bounce into file://,
        // gopher://, dict:// or other SSRF vectors.
        "--proto",
        "=http,https",
        "--proto-redir",
        "=http,https",
        "-sS",
        "--max-time",
        "20",
        "--write-out",
        status_marker ++ "%{http_code}" ++ ctype_marker ++ "%{content_type}" ++ url_marker ++ "%{url_effective}",
        url,
    };

    // Allow up to 8x max_bytes raw so we can capture pages with heavy
    // <script>/<style> that compress dramatically through html_to_text.
    // Without this, big landing pages (partiful.com, react docs, ...)
    // tripped StreamTooLong and surfaced as a useless "tool error".
    const fetch_cap = @max(@as(usize, 1024), max_bytes * 8 + status_marker.len + 64);
    const result = std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(fetch_cap),
        .stderr_limit = .limited(fetch_cap),
    }) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, "web fetch unavailable: curl is not installed"),
        // StreamTooLong: page exceeds even the inflated cap (8x
        // max_bytes). Re-fetch with a Range header so curl streams
        // only the first max_bytes bytes -- that's plenty for the
        // model to learn the site's structure / find an API hint.
        error.StreamTooLong => return webFetchRanged(allocator, cwd, url, max_bytes, prompt, fetch_ctx),
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const stdout_items = result.stdout;
    const stderr_items = result.stderr;
    const term = result.term;

    // If the spinner signalled cancel mid-request, surface that before
    // any "web fetch failed" message so the user knows it was their
    // action, not a network error.
    if (http_common.isCancelRequested()) {
        return allocator.dupe(u8, "web fetch cancelled by user");
    }

    if (!(term == .exited and term.exited == 0)) {
        return std.fmt.allocPrint(allocator, "web fetch failed\n{s}", .{stderr_items});
    }

    const parsed = parseCurlResponseWithStatus(stdout_items, status_marker, ctype_marker, url_marker) orelse {
        return allocator.dupe(u8, "web fetch failed: malformed curl response");
    };
    if (parsed.status_code >= 400) {
        const clipped_body = parsed.body[0..@min(parsed.body.len, max_bytes)];
        return std.fmt.allocPrint(allocator, "web fetch failed (status={d})\n{s}", .{ parsed.status_code, clipped_body });
    }

    // Cross-host redirect detection. We keep `curl -L` (so same-host and
    // www. add/remove redirects are followed silently, which is what we
    // want), then compare the requested URL against the effective URL curl
    // reported via %{url_effective}. If the host changed (or the scheme
    // changed), surface a REDIRECT DETECTED message instead of returning the
    // other host's body -- the model can re-call WebFetch with the redirect
    // URL. This post-hoc check is simpler than the reference's manual
    // maxRedirects:0 follow loop (utils.ts:262-329) and is sufficient for the
    // "surface a host change" goal. Deviation noted deliberately.
    if (parsed.effective_url.len > 0 and
        !url_host.sameHostModuloWww(url, parsed.effective_url))
    {
        return redirectDetectedMessage(allocator, url, parsed.effective_url, parsed.status_code, prompt);
    }

    // Binary content (PDF, image, archive, ...): we cannot hand raw binary
    // bytes back to the model as text, so persist the full body to a
    // session-scoped artifacts dir and return a short note naming the path
    // (mirrors WebFetchTool.ts:280-285 + utils.ts:442-449). The model can then
    // pass that file path to a file-aware tool instead of choking on binary
    // noise. We persist the FULL `parsed.body` (not the max_bytes-clipped
    // slice) so the on-disk artifact is the complete file.
    if (parsed.content_type.len > 0 and web_artifacts.isBinaryContentType(parsed.content_type)) {
        return persistBinaryWebFetch(allocator, url, parsed.body, parsed.content_type);
    }

    const take_len = @min(parsed.body.len, max_bytes);
    const clipped = parsed.body[0..take_len];

    // HTML cleanup: strip tags, scripts, styles, and HTML entities so
    // the model doesn't burn context on CSS rules and analytics
    // boilerplate. Ports the readable-text pipeline from
    // claude-code-main/src/tools/WebFetchTool (which uses turndown +
    // cheerio; we do a lighter-weight hand-rolled stripper --
    // see src/core/html_to_text.zig for the rationale).
    //
    // Escape hatch: `ZCODE_WEBFETCH_RAW=1` (or `CLAUDE_CODE_WEBFETCH_RAW=1`)
    // disables the stripper for power users that explicitly need the
    // raw markup (e.g. scraping attribute data, inspecting meta tags).
    const content: []u8 = if (!webFetchRawEnvSet() and bodyLooksLikeHtml(clipped))
        try html_to_text.htmlToText(allocator, clipped)
    else
        try allocator.dupe(u8, clipped);

    return finalizeWebFetch(allocator, url, content, prompt, fetch_ctx);
}

/// Persist a binary WebFetch body to disk and return a result that names the
/// saved file. The body bytes are written verbatim under the session artifacts
/// dir with a mime-derived extension; the returned text is the persisted note
/// (no leading content, since binary bytes are not human/model readable). On a
/// persistence failure we degrade gracefully to a note that the content was
/// binary but could not be saved, so WebFetch never hard-fails.
fn persistBinaryWebFetch(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    content_type: []const u8,
) ![]u8 {
    // Session segment: WebFetch has no session id threaded through today, so we
    // bucket binary artifacts under a stable "web_fetch" segment in the session
    // artifacts tree. This keeps the surgical-change footprint small while
    // still landing the file in the same artifacts directory layout the rest of
    // the tool output uses.
    var persisted = web_artifacts.persistBinaryContent(allocator, "web_fetch", body, content_type) catch |err| {
        return std.fmt.allocPrint(
            allocator,
            "[web_fetch: {s} returned binary content ({s}, {d} bytes); could not persist to disk: {s}]",
            .{ url, content_type, body.len, @errorName(err) },
        );
    };
    defer persisted.deinit(allocator);

    const note = try web_artifacts.persistedNote(allocator, content_type, persisted.size, persisted.path);
    defer allocator.free(note);

    // Trim the leading blank-line separator: with no preceding content the note
    // is the entire result, so it should not start with "\n\n".
    const trimmed = std.mem.trimStart(u8, note, "\n");
    return allocator.dupe(u8, trimmed);
}

/// Apply the post-fetch decision (raw vs summarize) to the stripped `content`.
/// Takes ownership of `content`: on the raw path it is returned directly; on the
/// summarize path it is summarized and freed. When summarization is requested
/// but no `fetch_ctx` is available (no model-call plumbing), the content is
/// returned raw so the tool never hard-fails.
fn finalizeWebFetch(
    allocator: std.mem.Allocator,
    url: []const u8,
    content: []u8,
    prompt: ?[]const u8,
    fetch_ctx: ?FetchContext,
) ![]u8 {
    switch (decideWebFetchResult(prompt, url, content)) {
        .raw => return content,
        .summarize => {
            const ctx = fetch_ctx orelse return content;
            defer allocator.free(content);
            return web_summarize.applyPromptToContent(allocator, ctx, prompt.?, content);
        },
    }
}

/// Fallback for pages so large they exceed even the inflated raw cap.
/// Issues a fresh curl with a Range header so only the first
/// `max_bytes * 2` bytes come over the wire. Returns a clearly-marked
/// truncated result instead of bubbling StreamTooLong up to the model
/// (which previously fired the "tool error: StreamTooLong" message in
/// screenshot 2026-05-17 21:45).
fn webFetchRanged(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    url: []const u8,
    max_bytes: usize,
    prompt: ?[]const u8,
    fetch_ctx: ?FetchContext,
) ![]u8 {
    const range_end = max_bytes * 2;
    var range_buf: [48]u8 = undefined;
    const range = std.fmt.bufPrint(&range_buf, "Range: bytes=0-{d}", .{range_end}) catch return allocator.dupe(u8, "web fetch failed: range header formatting error");
    const argv = [_][]const u8{
        "curl",
        "-sS",
        "--proto",
        "=http,https",
        "--proto-redir",
        "=http,https",
        "--max-time",
        "20",
        "--max-filesize",
        // curl's --max-filesize takes bytes
        // safe to inline since range_end <= 8 MB worst-case
        "5242880",
        "-H",
        range,
        url,
    };
    const result = std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(@max(@as(usize, 1024), range_end + 1024)),
        .stderr_limit = .limited(8 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, "web fetch unavailable: curl is not installed"),
        else => return std.fmt.allocPrint(
            allocator,
            "web fetch failed ({s}): the URL returned an unusually large page (> {d} KB). Try a more specific path (e.g. /api/docs, /docs, /reference) instead of the site root.",
            .{ @errorName(err), max_bytes / 1024 },
        ),
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!(result.term == .exited and result.term.exited == 0)) {
        return std.fmt.allocPrint(
            allocator,
            "web fetch failed: the URL returned an unusually large page. Try a more specific path or use WebSearch instead.\n{s}",
            .{result.stderr},
        );
    }
    const take_len = @min(result.stdout.len, max_bytes);
    const clipped = result.stdout[0..take_len];
    const body = if (!webFetchRawEnvSet() and bodyLooksLikeHtml(clipped))
        try html_to_text.htmlToText(allocator, clipped)
    else
        try allocator.dupe(u8, clipped);

    // When a prompt + summarization context are present, run the (already
    // truncated) body through the secondary model so the model gets a focused
    // answer rather than a wall of clipped text. Otherwise wrap the raw body
    // with the truncation note as before.
    if (prompt != null and fetch_ctx != null) {
        const summarized = try web_summarize.applyPromptToContent(allocator, fetch_ctx.?, prompt.?, body);
        defer allocator.free(summarized);
        allocator.free(body);
        return std.fmt.allocPrint(
            allocator,
            "[truncated: page exceeded {d} KB; first {d} bytes summarized via Range request]\n\n{s}",
            .{ max_bytes / 1024, take_len, summarized },
        );
    }
    defer allocator.free(body);
    return std.fmt.allocPrint(
        allocator,
        "[truncated: page exceeded {d} KB; showing first {d} bytes via Range request]\n\n{s}",
        .{ max_bytes / 1024, take_len, body },
    );
}

fn webFetchRawEnvSet() bool {
    const names = [_][]const u8{ "ZCODE_WEBFETCH_RAW", "CLAUDE_CODE_WEBFETCH_RAW" };
    for (names) |n| {
        if (@import("../core/env.zig").getenv(n)) |v| {
            if (std.mem.eql(u8, v, "1") or
                std.ascii.eqlIgnoreCase(v, "true") or
                std.ascii.eqlIgnoreCase(v, "yes")) return true;
        }
    }
    return false;
}

pub fn webSearch(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    query: []const u8,
    max_bytes: usize,
    allowed_domains: []const []const u8,
    blocked_domains: []const []const u8,
) ![]u8 {
    const encoded = try helpers.urlEncodeAlloc(allocator, query);
    defer allocator.free(encoded);
    const url = try std.fmt.allocPrint(
        allocator,
        "https://api.duckduckgo.com/?q={s}&format=json&no_html=1&skip_disambig=1",
        .{encoded},
    );
    defer allocator.free(url);
    const raw = try webFetch(allocator, cwd, url, max_bytes, null, null);
    defer allocator.free(raw);
    return summarizeInstantAnswer(allocator, query, raw, allowed_domains, blocked_domains);
}

/// Parse a domain-filter argument into a list of host strings. Tolerant of
/// two shapes (mirrors AskUserQuestion's `parseChoiceList`-style tolerance):
///   1. A JSON array string: `["wikipedia.org","example.com"]`
///   2. A comma- (or whitespace-) delimited string: `wikipedia.org, example.com`
/// Each entry is trimmed and a leading scheme / `www.` is stripped so the
/// model can pass `https://docs.foo.com` or `foo.com` interchangeably.
/// Returns an owned slice; the caller frees both the slice and each entry.
pub fn parseDomainList(allocator: std.mem.Allocator, raw: ?[]const u8) ![]const []const u8 {
    const r = raw orelse return allocator.alloc([]const u8, 0);
    const trimmed = std.mem.trim(u8, r, " \t\r\n");
    if (trimmed.len == 0) return allocator.alloc([]const u8, 0);

    var out = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (out.items) |it| allocator.free(it);
        out.deinit();
    }

    if (trimmed[0] == '[') {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
            // Malformed JSON -> fall back to delimited parsing of the raw text.
            try appendDelimitedDomains(allocator, &out, trimmed);
            return out.toOwnedSlice();
        };
        defer parsed.deinit();
        if (parsed.value == .array) {
            for (parsed.value.array.items) |item| {
                if (item == .string) {
                    if (normalizeDomain(item.string)) |d| {
                        try out.append(try allocator.dupe(u8, d));
                    }
                }
            }
            return out.toOwnedSlice();
        }
        // Not actually an array -> treat as delimited text.
        try appendDelimitedDomains(allocator, &out, trimmed);
        return out.toOwnedSlice();
    }

    try appendDelimitedDomains(allocator, &out, trimmed);
    return out.toOwnedSlice();
}

fn appendDelimitedDomains(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed([]const u8),
    raw: []const u8,
) !void {
    var it = std.mem.tokenizeAny(u8, raw, ", \t\r\n");
    while (it.next()) |tok| {
        if (normalizeDomain(tok)) |d| {
            try out.append(try allocator.dupe(u8, d));
        }
    }
}

/// Normalize a domain entry: strip a leading scheme (`https://`), strip a
/// leading `www.`, and drop any path/query/port tail so only the bare host
/// remains. Returns null for an empty result. Output is NOT lowercased --
/// `hostMatchesDomain` already compares case-insensitively.
fn normalizeDomain(entry: []const u8) ?[]const u8 {
    var d = std.mem.trim(u8, entry, " \t\r\n");
    // Strip a scheme prefix if present.
    if (std.mem.indexOf(u8, d, "://")) |idx| d = d[idx + 3 ..];
    // Strip a leading www.
    if (d.len > 4 and std.ascii.eqlIgnoreCase(d[0..4], "www.")) d = d[4..];
    // Cut at the first path / query / port separator.
    for (d, 0..) |c, i| {
        if (c == '/' or c == '?' or c == '#' or c == ':') {
            d = d[0..i];
            break;
        }
    }
    if (d.len == 0) return null;
    return d;
}

/// Host match against a domain filter entry: a result host matches a domain
/// either exactly or as a sub-domain (suffix on a `.` boundary). So
/// `foo.com` matches `docs.foo.com` but NOT `evil-foo.com`. Comparison is
/// case-insensitive.
fn hostMatchesDomain(host: []const u8, domain: []const u8) bool {
    if (host.len == 0 or domain.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(host, domain)) return true;
    // Sub-domain: host must end with ".<domain>" so the boundary is a real
    // label separator (anchors the suffix on a `.` so `evil-example.com` does
    // not match `example.com`).
    if (host.len > domain.len + 1) {
        const tail = host[host.len - domain.len ..];
        const sep = host[host.len - domain.len - 1];
        if (sep == '.' and std.ascii.eqlIgnoreCase(tail, domain)) return true;
    }
    return false;
}

/// True when a result URL passes the allowed/blocked domain filters.
/// Blocked wins: drop if the host matches any blocked domain. Then if the
/// allowed list is non-empty, keep only hosts that match an allowed domain.
/// A URL with no parseable host is dropped when an allow-list is present
/// (cannot prove it is allowed) and kept otherwise.
fn urlPassesDomainFilter(
    url: []const u8,
    allowed_domains: []const []const u8,
    blocked_domains: []const []const u8,
) bool {
    const host = ssrf_guard.extractHost(url);
    for (blocked_domains) |b| {
        if (host) |h| {
            if (hostMatchesDomain(h, b)) return false;
        }
    }
    if (allowed_domains.len == 0) return true;
    const h = host orelse return false;
    for (allowed_domains) |a| {
        if (hostMatchesDomain(h, a)) return true;
    }
    return false;
}

fn jsonStrField(v: std.json.Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const f = v.object.get(key) orelse return "";
    return switch (f) {
        .string => |s| s,
        else => "",
    };
}

/// Actionable message when the instant-answer API has nothing for `query`.
/// DuckDuckGo's keyless JSON endpoint only covers encyclopedic topics, so
/// product/API queries come back empty; steer the model to WebFetch the real
/// site instead of choking on empty JSON (which made weak models return an
/// empty response and stall).
fn searchGuidance(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "No web results for \"{s}\".\n" ++
            "This web_search returns only DuckDuckGo instant answers (encyclopedic topics), not general web results, " ++
            "so product/library/API queries usually come back empty.\n" ++
            "To research a specific product or API, call WebFetch directly on its site or docs " ++
            "(e.g. web_fetch url=\"https://<the-product>.com\" or its developer/login page), " ++
            "or ask the user for the exact docs URL. Do not just retry web_search with a reworded query.",
        .{query},
    );
}

/// Turn the DuckDuckGo instant-answer JSON into readable text. Returns the
/// Answer/Abstract/Definition and RelatedTopics when present; otherwise returns
/// actionable guidance. Falls back to passing `raw` through if it isn't the
/// expected JSON (e.g. webFetch returned an error string).
fn summarizeInstantAnswer(
    allocator: std.mem.Allocator,
    query: []const u8,
    raw: []const u8,
    allowed_domains: []const []const u8,
    blocked_domains: []const []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return allocator.dupe(u8, raw);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch
        return searchGuidance(allocator, query);
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return searchGuidance(allocator, query);

    const filtering = allowed_domains.len > 0 or blocked_domains.len > 0;

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    var any = false;

    const answer = jsonStrField(root, "Answer");
    const heading = jsonStrField(root, "Heading");
    const abstract = jsonStrField(root, "AbstractText");
    const abstract_url = jsonStrField(root, "AbstractURL");
    const definition = jsonStrField(root, "Definition");

    if (answer.len > 0) {
        try out.writer().print("{s}\n", .{answer});
        any = true;
    }
    // The abstract carries a Source URL -- gate it (and the whole abstract,
    // since its only locator is that URL) on the domain filter so a blocked
    // host does not leak through the abstract path.
    if (abstract.len > 0 and (!filtering or abstract_url.len == 0 or
        urlPassesDomainFilter(abstract_url, allowed_domains, blocked_domains)))
    {
        if (heading.len > 0) try out.writer().print("{s}\n", .{heading});
        try out.writer().print("{s}\n", .{abstract});
        if (abstract_url.len > 0) try out.writer().print("Source: {s}\n", .{abstract_url});
        any = true;
    } else if (definition.len > 0) {
        try out.writer().print("{s}\n", .{definition});
        any = true;
    }

    if (root.object.get("RelatedTopics")) |rt_val| {
        if (rt_val == .array) {
            var count: usize = 0;
            for (rt_val.array.items) |item| {
                if (count >= 8) break;
                const text = jsonStrField(item, "Text");
                if (text.len == 0) continue;
                const furl = jsonStrField(item, "FirstURL");
                // Filter by the topic's FirstURL host. A topic with no URL is
                // dropped when an allow-list is active (cannot prove allowed)
                // but kept when only a block-list is set.
                if (filtering) {
                    if (furl.len == 0) {
                        if (allowed_domains.len > 0) continue;
                    } else if (!urlPassesDomainFilter(furl, allowed_domains, blocked_domains)) {
                        continue;
                    }
                }
                if (!any) try out.writer().writeAll("Related results:\n");
                if (furl.len > 0) {
                    try out.writer().print("- {s} ({s})\n", .{ text, furl });
                } else {
                    try out.writer().print("- {s}\n", .{text});
                }
                any = true;
                count += 1;
            }
        }
    }

    if (!any) return searchGuidance(allocator, query);
    return allocator.dupe(u8, out.items());
}

const CurlResponseWithStatus = struct {
    body: []const u8,
    status_code: u16,
    /// The Content-Type header curl reported (%{content_type}), e.g.
    /// "application/pdf" or "text/html; charset=utf-8". Empty when curl
    /// emitted nothing (back-compat with the older status-only marker).
    content_type: []const u8 = "",
    /// The final URL after curl followed any redirects (%{url_effective}).
    /// Empty when curl emitted no effective URL (older curl, or the marker
    /// carried only a status code -- back-compat with the single-field form).
    effective_url: []const u8 = "",
};

/// Parse the curl stdout into body + the three trailing fields written by the
/// `--write-out` marker. `status_marker`, `ctype_marker`, and `url_marker` are
/// the three sub-markers (each on its own line) that prefix the status code,
/// the Content-Type, and the effective URL respectively. The body is everything
/// before the LAST `status_marker` occurrence; the other two fields are parsed
/// from the trailer that follows.
///
/// Back-compat: if the trailer has only a status code (older single-field
/// marker, used by the unit tests that pass just a status), `content_type` and
/// `effective_url` come back empty. A legacy `"<status> <url>"` space-joined
/// trailer (no sub-markers) is also still honored for the effective URL.
fn parseCurlResponseWithStatus(
    raw: []const u8,
    status_marker: []const u8,
    ctype_marker: []const u8,
    url_marker: []const u8,
) ?CurlResponseWithStatus {
    const marker_idx = std.mem.lastIndexOf(u8, raw, status_marker) orelse return null;
    const trailer_full = raw[marker_idx + status_marker.len ..];

    // The trailer is laid out as:
    //   <status>[ctype_marker<content_type>][url_marker<effective_url>]
    // Find the ctype/url sub-markers within the trailer; everything before
    // the first sub-marker is the status field.
    const ctype_idx = std.mem.indexOf(u8, trailer_full, ctype_marker);
    const url_idx = std.mem.indexOf(u8, trailer_full, url_marker);

    var content_type: []const u8 = "";
    var effective_url: []const u8 = "";

    // Status slice ends at the first sub-marker (whichever comes first), or the
    // end of the trailer when no sub-markers are present.
    var status_end: usize = trailer_full.len;
    if (ctype_idx) |ci| status_end = @min(status_end, ci);
    if (url_idx) |ui| status_end = @min(status_end, ui);

    if (ctype_idx) |ci| {
        const ct_start = ci + ctype_marker.len;
        const ct_end = if (url_idx) |ui| (if (ui > ci) ui else trailer_full.len) else trailer_full.len;
        content_type = std.mem.trim(u8, trailer_full[ct_start..ct_end], " \t\r\n");
    }
    if (url_idx) |ui| {
        effective_url = std.mem.trim(u8, trailer_full[ui + url_marker.len ..], " \t\r\n");
    }

    var status_slice = std.mem.trim(u8, trailer_full[0..status_end], " \t\r\n");
    if (status_slice.len == 0) return null;

    // Legacy space-joined "<status> <url>" trailer (no sub-markers): split on
    // the first space so older callers/tests still capture the effective URL.
    if (ctype_idx == null and url_idx == null) {
        if (std.mem.indexOfScalar(u8, status_slice, ' ')) |sp| {
            effective_url = std.mem.trim(u8, status_slice[sp + 1 ..], " \t\r\n");
            status_slice = status_slice[0..sp];
        }
    }

    const status_code = std.fmt.parseInt(u16, status_slice, 10) catch return null;
    return .{
        .body = raw[0..marker_idx],
        .status_code = status_code,
        .content_type = content_type,
        .effective_url = effective_url,
    };
}

/// Build a `domain:<host>` permission-rule suggestion for a WebFetch URL,
/// mirroring the reference's `webFetchToolInputToPermissionRuleContent`
/// (claude-code-main/src/tools/WebFetchTool.ts:50-64). The host is lowercased
/// (DNS is case-insensitive) so the suggestion is stable regardless of how the
/// model cased the URL. Returns null when the URL has no parseable host. Owned;
/// caller frees.
pub fn webFetchRuleContent(allocator: std.mem.Allocator, url: []const u8) !?[]u8 {
    const host = ssrf_guard.extractHost(url) orelse return null;
    if (host.len == 0) return null;
    const lowered = try std.ascii.allocLowerString(allocator, host);
    defer allocator.free(lowered);
    return try std.fmt.allocPrint(allocator, "domain:{s}", .{lowered});
}

/// Build the "REDIRECT DETECTED:" message surfaced when a fetch crossed to a
/// different host (or changed scheme). Mirrors the reference
/// (WebFetchTool.ts:216-249): name both URLs, the status, and instruct the
/// model to re-call WebFetch with the redirect URL (carrying the original
/// prompt). Pure -- no network -- so the result-shaping branch is unit-testable.
fn redirectDetectedMessage(
    allocator: std.mem.Allocator,
    requested_url: []const u8,
    effective_url: []const u8,
    status_code: u16,
    prompt: ?[]const u8,
) ![]u8 {
    if (prompt) |p| {
        return std.fmt.allocPrint(
            allocator,
            "REDIRECT DETECTED: The request to {s} was redirected to a different host: {s} (status {d}).\n" ++
                "WebFetch does not follow cross-host redirects automatically. " ++
                "To fetch the content, re-call WebFetch with url=\"{s}\" and prompt=\"{s}\".",
            .{ requested_url, effective_url, status_code, effective_url, p },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "REDIRECT DETECTED: The request to {s} was redirected to a different host: {s} (status {d}).\n" ++
            "WebFetch does not follow cross-host redirects automatically. " ++
            "To fetch the content, re-call WebFetch with url=\"{s}\".",
        .{ requested_url, effective_url, status_code, effective_url },
    );
}

const testing = std.testing;

test "summarizeInstantAnswer: empty instant-answer JSON returns actionable guidance" {
    const empty = "{\"Abstract\":\"\",\"AbstractText\":\"\",\"AbstractURL\":\"\",\"Answer\":\"\",\"Definition\":\"\",\"RelatedTopics\":[]}";
    const out = try summarizeInstantAnswer(testing.allocator, "Partiful API", empty, &.{}, &.{});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "No web results for \"Partiful API\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "WebFetch") != null);
    // must NOT leak the raw empty JSON that confused weak models
    try testing.expect(std.mem.indexOf(u8, out, "AbstractText") == null);
}

test "summarizeInstantAnswer: abstract + related topics rendered readably" {
    const json =
        \\{"Heading":"Python","AbstractText":"Python is a programming language.","AbstractURL":"https://en.wikipedia.org/wiki/Python","RelatedTopics":[{"Text":"Python (genus)","FirstURL":"https://duckduckgo.com/Python_genus"}]}
    ;
    const out = try summarizeInstantAnswer(testing.allocator, "python", json, &.{}, &.{});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Python is a programming language.") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Source: https://en.wikipedia.org/wiki/Python") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Python (genus)") != null);
}

test "summarizeInstantAnswer: passes through a non-JSON error body" {
    const err = "web fetch failed: curl is not installed";
    const out = try summarizeInstantAnswer(testing.allocator, "q", err, &.{}, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(err, out);
}

// A fixed JSON with two RelatedTopics on different hosts, used by the
// domain-filter tests below.
const two_host_topics_json =
    \\{"RelatedTopics":[{"Text":"Wiki article","FirstURL":"https://en.wikipedia.org/wiki/Foo"},{"Text":"Example page","FirstURL":"https://example.com/foo"}]}
;

test "summarizeInstantAnswer: blocked_domains drops matching results" {
    const blocked = [_][]const u8{"example.com"};
    const out = try summarizeInstantAnswer(testing.allocator, "foo", two_host_topics_json, &.{}, &blocked);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Wiki article") != null);
    try testing.expect(std.mem.indexOf(u8, out, "wikipedia.org") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Example page") == null);
    try testing.expect(std.mem.indexOf(u8, out, "example.com") == null);
}

test "summarizeInstantAnswer: allowed_domains keeps only matching results" {
    const allowed = [_][]const u8{"wikipedia.org"};
    const out = try summarizeInstantAnswer(testing.allocator, "foo", two_host_topics_json, &allowed, &.{});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Wiki article") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Example page") == null);
}

test "hostMatchesDomain: exact, suffix on a dot boundary, and no false suffix" {
    try testing.expect(hostMatchesDomain("example.com", "example.com"));
    try testing.expect(hostMatchesDomain("docs.foo.com", "foo.com"));
    try testing.expect(hostMatchesDomain("EXAMPLE.COM", "example.com"));
    // suffix without a dot boundary must NOT match
    try testing.expect(!hostMatchesDomain("evil-example.com", "example.com"));
    try testing.expect(!hostMatchesDomain("notexample.com", "example.com"));
    try testing.expect(!hostMatchesDomain("foo.com", "bar.com"));
}

test "urlPassesDomainFilter: blocked wins, allow-list gates" {
    const allowed = [_][]const u8{"wikipedia.org"};
    const blocked = [_][]const u8{"example.com"};
    try testing.expect(urlPassesDomainFilter("https://en.wikipedia.org/x", &allowed, &.{}));
    try testing.expect(!urlPassesDomainFilter("https://example.com/x", &allowed, &.{}));
    try testing.expect(!urlPassesDomainFilter("https://example.com/x", &.{}, &blocked));
    // blocked wins even if allowed also lists it
    try testing.expect(!urlPassesDomainFilter("https://example.com/x", &blocked, &blocked));
    // no filters -> everything passes
    try testing.expect(urlPassesDomainFilter("https://anything.io/x", &.{}, &.{}));
}

test "parseDomainList: JSON array form" {
    const list = try parseDomainList(testing.allocator, "[\"wikipedia.org\",\"https://docs.foo.com/x\"]");
    defer {
        for (list) |d| testing.allocator.free(d);
        testing.allocator.free(list);
    }
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("wikipedia.org", list[0]);
    // scheme + path stripped to bare host
    try testing.expectEqualStrings("docs.foo.com", list[1]);
}

test "parseDomainList: comma-delimited form and www stripping" {
    const list = try parseDomainList(testing.allocator, "www.example.com, foo.com");
    defer {
        for (list) |d| testing.allocator.free(d);
        testing.allocator.free(list);
    }
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("example.com", list[0]);
    try testing.expectEqualStrings("foo.com", list[1]);
}

test "parseDomainList: null and empty yield empty list" {
    const a = try parseDomainList(testing.allocator, null);
    defer testing.allocator.free(a);
    try testing.expectEqual(@as(usize, 0), a.len);
    const b = try parseDomainList(testing.allocator, "   ");
    defer testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 0), b.len);
}

test "decideWebFetchResult: null prompt returns raw unchanged" {
    // No prompt -> always raw (current behavior preserved).
    try testing.expectEqual(PostFetchDecision.raw, decideWebFetchResult(null, "https://example.com/x", "any content"));
    try testing.expectEqual(PostFetchDecision.raw, decideWebFetchResult(null, "https://docs.python.org/3/", "plain text"));
}

test "decideWebFetchResult: preapproved markdown URL under MAX bypasses summarization" {
    // Preapproved host + short plain-text content + a prompt -> still raw.
    try testing.expectEqual(
        PostFetchDecision.raw,
        decideWebFetchResult("what is asyncio?", "https://docs.python.org/3/library/asyncio.html", "asyncio is a library for async IO."),
    );
}

test "decideWebFetchResult: non-preapproved host with prompt summarizes" {
    try testing.expectEqual(
        PostFetchDecision.summarize,
        decideWebFetchResult("summarize", "https://blog.example.com/post", "Some article text."),
    );
}

test "decideWebFetchResult: preapproved but over MAX summarizes" {
    const big = [_]u8{'a'} ** (web_summarize.MAX_MARKDOWN_LENGTH + 10);
    try testing.expectEqual(
        PostFetchDecision.summarize,
        decideWebFetchResult("summarize", "https://docs.python.org/3/", &big),
    );
}

// Shared marker strings so tests exercise the same sub-marker layout the
// production curl `--write-out` argument emits.
const TEST_STATUS_MARKER = "\n__ZCODE_WEB_STATUS__:";
const TEST_CTYPE_MARKER = "\n__ZCODE_WEB_CTYPE__:";
const TEST_URL_MARKER = "\n__ZCODE_WEB_URL__:";

test "parseCurlResponseWithStatus splits body and code" {
    const parsed = parseCurlResponseWithStatus(
        "hello\n__ZCODE_WEB_STATUS__:404",
        TEST_STATUS_MARKER,
        TEST_CTYPE_MARKER,
        TEST_URL_MARKER,
    ) orelse return error.TestUnexpectedResult;

    try testing.expectEqual(@as(u16, 404), parsed.status_code);
    try testing.expectEqualStrings("hello", parsed.body);
    // Single-field (legacy) trailer leaves content_type and effective_url empty.
    try testing.expectEqualStrings("", parsed.content_type);
    try testing.expectEqualStrings("", parsed.effective_url);
}

test "parseCurlResponseWithStatus splits body, code, and effective URL (legacy space-joined)" {
    const parsed = parseCurlResponseWithStatus(
        "page body\n__ZCODE_WEB_STATUS__:200 https://www.example.com/final",
        TEST_STATUS_MARKER,
        TEST_CTYPE_MARKER,
        TEST_URL_MARKER,
    ) orelse return error.TestUnexpectedResult;

    try testing.expectEqual(@as(u16, 200), parsed.status_code);
    try testing.expectEqualStrings("page body", parsed.body);
    try testing.expectEqualStrings("https://www.example.com/final", parsed.effective_url);
}

test "parseCurlResponseWithStatus splits body, code, content-type, and effective URL" {
    // Content-Type carries a `; charset=...` parameter (with a space) -- the
    // sub-marker layout must keep it intact and not bleed into the status or
    // the URL.
    const raw =
        "page body" ++
        "\n__ZCODE_WEB_STATUS__:200" ++
        "\n__ZCODE_WEB_CTYPE__:text/html; charset=utf-8" ++
        "\n__ZCODE_WEB_URL__:https://www.example.com/final";
    const parsed = parseCurlResponseWithStatus(
        raw,
        TEST_STATUS_MARKER,
        TEST_CTYPE_MARKER,
        TEST_URL_MARKER,
    ) orelse return error.TestUnexpectedResult;

    try testing.expectEqual(@as(u16, 200), parsed.status_code);
    try testing.expectEqualStrings("page body", parsed.body);
    try testing.expectEqualStrings("text/html; charset=utf-8", parsed.content_type);
    try testing.expectEqualStrings("https://www.example.com/final", parsed.effective_url);
}

test "parseCurlResponseWithStatus captures a binary content-type" {
    const raw =
        "%PDF-1.4 binary bytes here" ++
        "\n__ZCODE_WEB_STATUS__:200" ++
        "\n__ZCODE_WEB_CTYPE__:application/pdf" ++
        "\n__ZCODE_WEB_URL__:https://files.example.com/doc.pdf";
    const parsed = parseCurlResponseWithStatus(
        raw,
        TEST_STATUS_MARKER,
        TEST_CTYPE_MARKER,
        TEST_URL_MARKER,
    ) orelse return error.TestUnexpectedResult;

    try testing.expectEqual(@as(u16, 200), parsed.status_code);
    try testing.expectEqualStrings("%PDF-1.4 binary bytes here", parsed.body);
    try testing.expectEqualStrings("application/pdf", parsed.content_type);
    try testing.expect(web_artifacts.isBinaryContentType(parsed.content_type));
}

test "webFetchRuleContent: builds a lowercased domain rule from the URL host" {
    const rule = (try webFetchRuleContent(testing.allocator, "https://Docs.FOO.com/x/y")) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(rule);
    try testing.expectEqualStrings("domain:docs.foo.com", rule);
}

test "webFetchRuleContent: returns null for a non-URL string" {
    try testing.expect((try webFetchRuleContent(testing.allocator, "not a url")) == null);
}

test "redirectDetectedMessage: cross-host effective URL produces REDIRECT DETECTED with both URLs" {
    // Synthesize a parsed curl response whose effective URL host differs from
    // the requested host -- the result string must begin with REDIRECT
    // DETECTED and name both URLs (network-free, mirrors the webFetch branch).
    const requested = "https://bit.ly/abc";
    const parsed = parseCurlResponseWithStatus(
        "ignored body\n__ZCODE_WEB_STATUS__:200 https://docs.example.com/real-page",
        TEST_STATUS_MARKER,
        TEST_CTYPE_MARKER,
        TEST_URL_MARKER,
    ) orelse return error.TestUnexpectedResult;

    try testing.expect(!url_host.sameHostModuloWww(requested, parsed.effective_url));

    const msg = try redirectDetectedMessage(testing.allocator, requested, parsed.effective_url, parsed.status_code, "what is on this page?");
    defer testing.allocator.free(msg);

    try testing.expect(std.mem.startsWith(u8, msg, "REDIRECT DETECTED:"));
    try testing.expect(std.mem.indexOf(u8, msg, requested) != null);
    try testing.expect(std.mem.indexOf(u8, msg, "https://docs.example.com/real-page") != null);
    // The original prompt is carried into the re-call instruction.
    try testing.expect(std.mem.indexOf(u8, msg, "what is on this page?") != null);
}

test "redirectDetectedMessage: same host is not surfaced as a redirect" {
    // www. add/remove and same-host path changes are NOT cross-host hops.
    try testing.expect(url_host.sameHostModuloWww("https://example.com/a", "https://www.example.com/b"));
}
