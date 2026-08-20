const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const rng = @import("rng.zig");
const clock = @import("clock.zig");
const paths = @import("paths.zig");
const parse_helpers = @import("parse_helpers.zig");

pub const AuditLogger = struct {
    allocator: std.mem.Allocator,
    file: std.Io.File,
    hmac_key: [32]u8,
    prev_hash: [32]u8,
    redact_prompt_bodies: bool = false,

    pub fn init(allocator: std.mem.Allocator, log_dir: []const u8) !AuditLogger {
        return initWithRetention(allocator, log_dir, 90);
    }

    pub fn setRedactPromptBodies(self: *AuditLogger, value: bool) void {
        self.redact_prompt_bodies = value;
    }

    pub fn initWithRetention(allocator: std.mem.Allocator, log_dir: []const u8, retention_days: u32) !AuditLogger {
        try paths.ensureDir(log_dir);

        const day_bucket: i64 = @divTrunc(clock.nowSeconds(), 86_400);
        const filename = try std.fmt.allocPrint(allocator, "audit-{d}.jsonl", .{day_bucket});
        defer allocator.free(filename);

        const log_path = try std.fs.path.join(allocator, &.{ log_dir, filename });
        defer allocator.free(log_path);

        // Set mode=0o600 at creation so the audit log is never briefly
        // world-readable in the window between createFile and chmod. The
        // post-create chmod stays as a safety net in case the file
        // already existed with wider permissions (umask only applies to
        // the create-new path).
        const file = try std.Io.Dir.cwd().createFile(rt.io, log_path, .{ .read = true, .truncate = false, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch |err| {
            std.log.warn("audit: chmod failed for log file: {s}", .{@errorName(err)});
        };

        // Reseed the tamper-evident chain hash from the last complete line in
        // the existing audit file. Without this, every process restart resets
        // `prev_hash` to zero, which lets an attacker truncate the file after
        // a restart and produce a chain that still validates from that point
        // forward. reseedPrevHashFromFile leaves the file seek position at end.
        //
        // On failure we fall back to a zero chain (so audit is still written)
        // but warn loudly: a silent fallback would mean the tamper-evident
        // chain is broken without the operator ever noticing.
        const prev_hash = reseedPrevHashFromFile(file) catch |err| blk: {
            std.log.warn("audit: failed to reseed chain hash ({s}); tamper evidence will restart from zero", .{@errorName(err)});
            break :blk [_]u8{0} ** 32;
        };
        // 0.16: no seek API; subsequent writes use writePositionalAll
        // with the current file length to append.

        // Load or generate HMAC key for log integrity. Fail hard on
        // any error instead of degrading to a zero-key fallback -- a
        // zero key makes every subsequent entry trivially forgeable
        // by anyone with log-dir write access, and the previous
        // behaviour silently accepted that. Operators now see the
        // error at startup and can fix permissions / rotate the key
        // before the session continues.
        const hmac_key = loadOrCreateHmacKey(allocator, log_dir) catch |err| {
            std.log.err("audit: failed to load/create HMAC key ({s}); refusing to start the logger with an insecure key. Fix the permissions on {s}/hmac.key or delete the file to regenerate.", .{ @errorName(err), log_dir });
            file.close(rt.io);
            return err;
        };

        // Run log retention cleanup.
        if (retention_days > 0) {
            cleanupOldLogs(allocator, log_dir, day_bucket, retention_days) catch |err| {
                std.log.debug("audit log retention cleanup failed: {s}", .{@errorName(err)});
            };
        }

        return .{
            .allocator = allocator,
            .file = file,
            .hmac_key = hmac_key,
            .prev_hash = prev_hash,
        };
    }

    pub fn deinit(self: *AuditLogger) void {
        self.file.close(rt.io);
    }

    pub fn log(self: *AuditLogger, event_type: []const u8, payload: []const u8) !void {
        const secret_redacted = try redactSecrets(self.allocator, payload);
        defer self.allocator.free(secret_redacted);
        const redacted_payload = if (self.redact_prompt_bodies)
            try redactPromptBodies(self.allocator, secret_redacted)
        else
            try self.allocator.dupe(u8, secret_redacted);
        defer self.allocator.free(redacted_payload);

        const ts = clock.nowSeconds();

        // Compute HMAC over: prev_hash ++ ts ++ event ++ payload.
        const hmac_hex = try computeEntryHmac(self.allocator, self.hmac_key, self.prev_hash, ts, event_type, redacted_payload);
        defer self.allocator.free(hmac_hex);

        // Stage the JSON into a scratch buffer so we can run the
        // ndjson-safe post-processor over it before appending to the
        // file. Escapes U+2028/U+2029 so external log-shippers that
        // split on ECMA-262 line terminators don't chop a line in
        // half when the payload happens to contain one of those
        // code points. Matches the reference's ndjsonSafeStringify.
        var scratch = std_io.StringBuilder.init(self.allocator);
        defer scratch.deinit();
        try scratch.writer().print("{f}", .{std.json.fmt(.{
            .ts = ts,
            .event = event_type,
            .payload = redacted_payload,
            .hmac = hmac_hex,
        }, .{})});

        var buf = std_io.StringBuilder.init(self.allocator);
        defer buf.deinit();
        try parse_helpers.appendNdjsonSafe(&buf, scratch.items());
        try buf.append('\n');

        // Update chain hash for next entry.
        std.crypto.hash.sha2.Sha256.hash(buf.items(), &self.prev_hash, .{});

        // 0.16: no streaming-append cursor; explicitly write at end-of-file.
        const eof = try self.file.length(rt.io);
        _ = try self.file.writePositionalAll(rt.io, buf.items(), eof);
        try self.file.sync(rt.io);
    }
};

pub const VerifyResult = struct {
    entries: usize,
    ok: bool,
    first_bad_line: usize = 0,
    reason: []const u8 = "",
};

/// Walk an audit log file, recomputing the HMAC + chain hash for
/// every line in order. Returns `ok=true` if the chain validates
/// end-to-end, `ok=false` with the offending line number and a short
/// reason otherwise.
///
/// Uses the HMAC key stored in `<log_dir>/hmac.key` - the same key
/// the writer used. An attacker who can forge the HMAC key can also
/// forge the chain, so the key file must be protected (it's created
/// mode 0600 by `loadOrCreateHmacKey`).
pub fn verifyLog(
    allocator: std.mem.Allocator,
    log_dir: []const u8,
    log_path: []const u8,
) !VerifyResult {
    // `verify` is strictly read-only. Use the load-only helper so a
    // missing `hmac.key` surfaces as "cannot verify" rather than
    // silently regenerating a fresh key and reporting every entry as
    // tampered. Regenerating would also mint a new key on the
    // analyst's forensic-copy machine and poison its audit chain.
    const key = loadHmacKeyReadOnly(allocator, log_dir) catch |err| switch (err) {
        error.HmacKeyMissing => return .{ .entries = 0, .ok = false, .reason = "HMAC key missing; cannot verify (copy hmac.key alongside the log)" },
        else => return err,
    };

    const content = try std.Io.Dir.cwd().readFileAlloc(rt.io, log_path, allocator, .limited(1024 * 1024 * 1024));
    defer allocator.free(content);

    var prev_hash = [_]u8{0} ** 32;
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        line_no += 1;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
            return .{ .entries = line_no, .ok = false, .first_bad_line = line_no, .reason = "line is not valid JSON" };
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            return .{ .entries = line_no, .ok = false, .first_bad_line = line_no, .reason = "line is not a JSON object" };
        }
        const obj = parsed.value.object;
        const ts_val = obj.get("ts") orelse return .{ .entries = line_no, .ok = false, .first_bad_line = line_no, .reason = "missing ts" };
        if (ts_val != .integer) return .{ .entries = line_no, .ok = false, .first_bad_line = line_no, .reason = "ts not integer" };
        const event_str = switch (obj.get("event") orelse return .{ .entries = line_no, .ok = false, .first_bad_line = line_no, .reason = "missing event" }) {
            .string => |s| s,
            else => return .{ .entries = line_no, .ok = false, .first_bad_line = line_no, .reason = "event not string" },
        };
        const payload_str = switch (obj.get("payload") orelse return .{ .entries = line_no, .ok = false, .first_bad_line = line_no, .reason = "missing payload" }) {
            .string => |s| s,
            else => return .{ .entries = line_no, .ok = false, .first_bad_line = line_no, .reason = "payload not string" },
        };
        const hmac_str = switch (obj.get("hmac") orelse return .{ .entries = line_no, .ok = false, .first_bad_line = line_no, .reason = "missing hmac" }) {
            .string => |s| s,
            else => return .{ .entries = line_no, .ok = false, .first_bad_line = line_no, .reason = "hmac not string" },
        };

        const expected_hmac = try computeEntryHmac(allocator, key, prev_hash, ts_val.integer, event_str, payload_str);
        defer allocator.free(expected_hmac);
        // Constant-time compare. HMAC verification with std.mem.eql
        // short-circuits on the first mismatched byte; an attacker who
        // can both write log lines and time the verifier (a CI runner
        // verifying ingested logs, a forensic analyst's forge attempt,
        // etc.) could probe the HMAC byte-by-byte. Even with a local
        // key the constant-time pattern is the right default for
        // anything labelled "HMAC".
        if (!constantTimeBytesEql(expected_hmac, hmac_str)) {
            return .{ .entries = line_no, .ok = false, .first_bad_line = line_no, .reason = "HMAC mismatch (line tampered or chain broken)" };
        }

        // Rebuild the on-disk line byte-for-byte so the chain hash we
        // compute here matches what the writer produced.
        var rebuilt = std_io.StringBuilder.init(allocator);
        defer rebuilt.deinit();
        try rebuilt.appendSlice(raw);
        try rebuilt.append('\n');
        std.crypto.hash.sha2.Sha256.hash(rebuilt.items(), &prev_hash, .{});
    }

    return .{ .entries = line_no, .ok = true };
}

/// Re-derive the chain hash that `log()` would have produced for the last
/// complete line of the existing audit file, so appending continues the
/// cryptographic chain across process restarts. Returns a zero-filled hash
/// when the file is empty.
fn reseedPrevHashFromFile(file: std.Io.File) ![32]u8 {
    var prev_hash = [_]u8{0} ** 32;
    const end_pos = try file.length(rt.io);
    if (end_pos == 0) return prev_hash;

    // Read the tail of the file so we can find the last complete line.
    // 64 KiB is enough for even pathologically-large single JSON lines.
    const tail_cap: u64 = 64 * 1024;
    const tail_len: u64 = @min(end_pos, tail_cap);
    const tail_start = end_pos - tail_len;

    var tail_buf: [64 * 1024]u8 = undefined;
    const slice = tail_buf[0..@intCast(tail_len)];
    const read_len = try file.readPositionalAll(rt.io, slice, tail_start);
    const tail = slice[0..read_len];
    if (read_len == 0) return prev_hash;

    // The last complete line ends with '\n'. If the final byte isn't '\n'
    // the file was partially written; fall back to the previous complete
    // line so we don't chain against torn content.
    var end: usize = read_len;
    while (end > 0 and tail[end - 1] != '\n') : (end -= 1) {}
    if (end == 0) return prev_hash;

    // Walk backwards to the newline that precedes the final line, so the
    // slice [line_start..end] captures exactly the last line including its
    // trailing newline — which is what log() hashed when it was written.
    var line_start: usize = end - 1; // skip the final newline we just found
    while (line_start > 0 and tail[line_start - 1] != '\n') : (line_start -= 1) {}

    // If we scanned all the way to offset 0 of the tail slice but the
    // tail did NOT start at byte 0 of the file, then the last line is
    // longer than tail_cap and what we have is a suffix rather than a
    // full line. Hashing that suffix would silently corrupt the chain,
    // so warn and break the chain cleanly from zero instead.
    if (line_start == 0 and tail_start > 0) {
        std.log.warn("audit: last line exceeds {d} bytes; restarting chain hash from zero", .{tail_cap});
        return [_]u8{0} ** 32;
    }

    const last_line = tail[line_start..end];
    std.crypto.hash.sha2.Sha256.hash(last_line, &prev_hash, .{});
    return prev_hash;
}

/// Constant-time byte-slice equality. The length check is intentionally
/// non-constant-time -- HMAC outputs are a fixed 64-hex-char width here,
/// so a length mismatch means a corrupted line, not a timing oracle for
/// a secret. The per-byte loop accumulates differences via XOR | OR
/// instead of returning early on the first mismatch, which is the
/// standard pattern for HMAC compare.
fn constantTimeBytesEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

fn computeEntryHmac(allocator: std.mem.Allocator, key: [32]u8, prev_hash: [32]u8, ts: i64, event: []const u8, payload: []const u8) ![]u8 {
    var hasher = std.crypto.auth.hmac.sha2.HmacSha256.init(&key);
    hasher.update(&prev_hash);
    var ts_buf: [20]u8 = undefined;
    const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{ts}) catch "0";
    hasher.update(ts_str);
    hasher.update(event);
    hasher.update(payload);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    for (digest) |byte| {
        try out.writer().print("{x:0>2}", .{byte});
    }
    return out.toOwnedSlice();
}

/// Load an existing HMAC key without creating a new one. Returns
/// `error.HmacKeyMissing` when the file does not exist,
/// `error.InvalidHmacKey` when it is not exactly 32 bytes, and
/// `error.InsecureHmacKeyPermissions` when group/world can read or
/// write it. Used by `verifyLog` so read-only verification never writes
/// to the log dir.
fn loadHmacKeyReadOnly(allocator: std.mem.Allocator, log_dir: []const u8) ![32]u8 {
    const key_path = try std.fs.path.join(allocator, &.{ log_dir, "hmac.key" });
    defer allocator.free(key_path);

    try validateHmacKeyFilePermissions(key_path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, key_path, allocator, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return error.HmacKeyMissing,
        else => return err,
    };
    defer allocator.free(bytes);
    return parseHmacKeyBytes(bytes);
}

fn loadOrCreateHmacKey(allocator: std.mem.Allocator, log_dir: []const u8) ![32]u8 {
    const key_path = try std.fs.path.join(allocator, &.{ log_dir, "hmac.key" });
    defer allocator.free(key_path);

    if (std.Io.Dir.cwd().readFileAlloc(rt.io, key_path, allocator, .limited(4096))) |bytes| {
        defer allocator.free(bytes);
        try validateHmacKeyFilePermissions(key_path);
        return parseHmacKeyBytes(bytes);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    // Generate new key.
    var key: [32]u8 = undefined;
    rng.secureBytes(&key);

    const parent = std.fs.path.dirname(key_path) orelse return error.InvalidPath;
    try paths.ensureDir(parent);
    // Atomic write: a SIGINT between createFile (which truncates to
    // 0 bytes) and writeAll would leave a 0-byte hmac.key, and on
    // next start loadOrCreateHmacKey would generate a *new* random
    // key -- silently invalidating the HMAC chain over every prior
    // audit entry, the exact tamper-evidence signal we built the
    // chain for. Same pattern as src/core/keychain.zig::loadOrCreateSeed.
    try writeKeyFileAtomic(allocator, key_path, &key);
    return key;
}

fn parseHmacKeyBytes(bytes: []const u8) ![32]u8 {
    if (bytes.len != 32) return error.InvalidHmacKey;
    var key: [32]u8 = undefined;
    @memcpy(&key, bytes[0..32]);
    return key;
}

fn validateHmacKeyFilePermissions(key_path: []const u8) !void {
    const stat = std.Io.Dir.cwd().statFile(rt.io, key_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.HmacKeyMissing,
        else => return err,
    };
    if ((stat.permissions.toMode() & 0o077) != 0) return error.InsecureHmacKeyPermissions;
}

fn writeKeyFileAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    var nonce: [8]u8 = undefined;
    rng.secureBytes(&nonce);
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
        file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch |err| {
            std.log.warn("audit: chmod failed for HMAC key tmp file: {s}", .{@errorName(err)});
        };
    }
    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

fn cleanupOldLogs(allocator: std.mem.Allocator, log_dir: []const u8, current_bucket: i64, retention_days: u32) !void {
    var dir = try std.Io.Dir.cwd().openDir(rt.io, log_dir, .{ .iterate = true });
    defer dir.close(rt.io);

    const cutoff = current_bucket - @as(i64, @intCast(retention_days));

    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "audit-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        // Extract day bucket from filename: audit-{bucket}.jsonl
        const stem = entry.name["audit-".len .. entry.name.len - ".jsonl".len];
        const bucket = std.fmt.parseInt(i64, stem, 10) catch continue;
        if (bucket < cutoff) {
            const path = try std.fs.path.join(allocator, &.{ log_dir, entry.name });
            defer allocator.free(path);
            std.Io.Dir.cwd().deleteFile(rt.io, path) catch {};
        }
    }
}

/// Privacy mode: redact prompt/response bodies from a JSON payload
/// while leaving metadata intact. Matches JSON keys that tend to
/// carry model-facing text and replaces their string values with a
/// fixed sentinel. Key list is intentionally conservative - dashboards
/// keep tool names, timings, token counts, and the event name so
/// ops can still read the audit log without exposing prompt content.
///
/// Callers should apply this AFTER redactSecrets. Keeping them
/// separate lets secret redaction stay on for every entry even when
/// privacy mode is off.
fn redactPromptBodies(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    const sensitive_keys = [_][]const u8{
        "prompt",
        "text",
        "content",
        "input",
        "output",
        "response",
        "message",
        "body",
        "system",
        "user_message",
        "assistant_message",
    };
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < payload.len) {
        if (payload[i] == '"') {
            var match: ?usize = null;
            for (sensitive_keys) |key| {
                // Look for "<key>":
                if (i + key.len + 2 >= payload.len) continue;
                if (payload[i + 1 + key.len] != '"') continue;
                if (!std.mem.eql(u8, payload[i + 1 .. i + 1 + key.len], key)) continue;
                var j = i + 1 + key.len + 1;
                while (j < payload.len and (payload[j] == ' ' or payload[j] == '\t')) : (j += 1) {}
                if (j < payload.len and payload[j] == ':') {
                    match = j + 1;
                    break;
                }
            }
            if (match) |after_colon| {
                var v = after_colon;
                while (v < payload.len and (payload[v] == ' ' or payload[v] == '\t')) : (v += 1) {}
                if (v < payload.len and payload[v] == '"') {
                    // Copy through the opening quote of the value, then
                    // replace value with sentinel, then skip to closing
                    // quote.
                    try out.appendSlice(payload[i..v]);
                    try out.appendSlice("\"[REDACTED-BODY]\"");
                    var end = v + 1;
                    while (end < payload.len and payload[end] != '"') : (end += 1) {
                        if (payload[end] == '\\' and end + 1 < payload.len) end += 1;
                    }
                    i = if (end < payload.len) end + 1 else end;
                    continue;
                }
            }
        }
        try out.append(payload[i]);
        i += 1;
    }

    return out.toOwnedSlice();
}

fn redactSecrets(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    var i: usize = 0;
    while (i < payload.len) {
        // JSON-aware pre-pass: recognise a `"key":"value"` pair where
        // the key name looks sensitive (token, secret, key, credential,
        // password, auth, authorization) and redact the value regardless
        // of its content. Catches provider-specific tokens that don't
        // match any known prefix (DeepSeek, Azure, Groq, OpenRouter).
        // Optional whitespace is tolerated between colon and value as
        // std.json emits compact but external logs may not be.
        if (payload[i] == '"') {
            if (matchJsonSensitiveKey(payload[i..])) |after_colon_off| {
                // Everything up through the colon + whitespace gets
                // copied verbatim; the string value that follows gets
                // a fixed "[REDACTED]" token. Non-string values
                // (null, numbers, objects) fall through to the
                // default byte walker.
                const key_end = i + after_colon_off;
                var v = key_end;
                while (v < payload.len and (payload[v] == ' ' or payload[v] == '\t')) : (v += 1) {}
                if (v < payload.len and payload[v] == '"') {
                    const value_start = v + 1;
                    // Find the closing quote, honouring backslash escapes.
                    var end = value_start;
                    while (end < payload.len) : (end += 1) {
                        if (payload[end] == '\\' and end + 1 < payload.len) {
                            end += 1;
                            continue;
                        }
                        if (payload[end] == '"') break;
                    }
                    if (end < payload.len and payload[end] == '"') {
                        try out.appendSlice(payload[i..v]);
                        try out.appendSlice("\"[REDACTED]\"");
                        i = end + 1;
                        continue;
                    }
                }
            }
        }

        // Known API key prefixes.
        if (startsWithAny(payload[i..], &.{
            "sk-",      "AIza",     "xoxb-",    "ghp_",
            "ghu_",     "glpat-",   "glu_",     "xoxp-",
            "xoxs-",    "AKIA",     "sk_live_", "sk_test_",
            "rk_live_", "rk_test_", "pk_live_", "pk_test_",
            "SG.",      "npm_",     "pypi-",
        })) |prefix_len| {
            try out.appendSlice("[REDACTED]");
            i += prefix_len;

            while (i < payload.len and isSecretChar(payload[i])) : (i += 1) {}
            continue;
        }

        // JWT tokens (base64-encoded JSON header).
        if (std.mem.startsWith(u8, payload[i..], "eyJ")) {
            try out.appendSlice("[REDACTED]");
            while (i < payload.len and (isSecretChar(payload[i]) or payload[i] == '=')) : (i += 1) {}
            continue;
        }

        // Database and message broker connection strings.
        if (startsWithConnectionScheme(payload[i..])) {
            try out.appendSlice("[REDACTED]");
            while (i < payload.len and !std.ascii.isWhitespace(payload[i]) and payload[i] != '"' and payload[i] != '\'') : (i += 1) {}
            continue;
        }

        // Slack webhook URLs.
        if (std.mem.startsWith(u8, payload[i..], "hooks.slack.com/services/")) {
            try out.appendSlice("[REDACTED]");
            while (i < payload.len and !std.ascii.isWhitespace(payload[i]) and payload[i] != '"' and payload[i] != '\'') : (i += 1) {}
            continue;
        }

        // Generic long token detection: sequences of 20+ alphanumeric/secret chars
        // that look like API keys or bearer tokens (mix of upper, lower, digits).
        if (isSecretChar(payload[i]) and looksLikeLongSecret(payload[i..])) {
            try out.appendSlice("[REDACTED]");
            while (i < payload.len and isSecretChar(payload[i])) : (i += 1) {}
            continue;
        }

        try out.append(payload[i]);
        i += 1;
    }

    return out.toOwnedSlice();
}

fn looksLikeLongSecret(input: []const u8) bool {
    const min_secret_len = 20;
    var len: usize = 0;
    var has_upper = false;
    var has_lower = false;
    var has_digit = false;

    for (input) |ch| {
        if (!isSecretChar(ch)) break;
        len += 1;
        if (std.ascii.isUpper(ch)) has_upper = true;
        if (std.ascii.isLower(ch)) has_lower = true;
        if (std.ascii.isDigit(ch)) has_digit = true;
    }

    // Must be at least 20 chars and have mixed case + digits to qualify.
    return len >= min_secret_len and has_upper and has_lower and has_digit;
}

fn startsWithAny(input: []const u8, prefixes: []const []const u8) ?usize {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, input, prefix)) return prefix.len;
    }
    return null;
}

/// If `input` starts with a JSON string key matching a sensitive-name
/// pattern ("token", "secret", "key", "credential", "password",
/// "auth", "authorization") followed by `:`, returns the byte offset
/// of the first byte after the colon (so the caller can skip over
/// whitespace and enter the value). Case-insensitive. Returns null
/// when the input isn't a `"sensitiveKey":` opener.
fn matchJsonSensitiveKey(input: []const u8) ?usize {
    if (input.len == 0 or input[0] != '"') return null;

    // Find the closing quote of the key (no escapes expected in
    // real-world keys; be strict).
    var end: usize = 1;
    while (end < input.len and input[end] != '"') : (end += 1) {}
    if (end == input.len) return null;
    const key = input[1..end];
    if (key.len == 0 or key.len > 64) return null;

    const patterns = [_][]const u8{
        "token",    "secret", "key",         "credential",
        "password", "passwd", "auth",        "authorization",
        "api_key",  "apikey", "private_key",
    };
    var hit = false;
    for (patterns) |p| {
        if (containsIgnoreCaseAscii(key, p)) {
            hit = true;
            break;
        }
    }
    if (!hit) return null;

    // Expect optional whitespace then ':'.
    var i = end + 1;
    while (i < input.len and (input[i] == ' ' or input[i] == '\t')) : (i += 1) {}
    if (i >= input.len or input[i] != ':') return null;
    return i + 1;
}

fn containsIgnoreCaseAscii(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    const last = haystack.len - needle.len + 1;
    var i: usize = 0;
    while (i < last) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

fn startsWithConnectionScheme(input: []const u8) bool {
    const schemes = [_][]const u8{
        "postgres://", "postgresql://",  "mysql://",
        "mongodb://",  "mongodb+srv://", "redis://",
        "rediss://",   "amqp://",        "amqps://",
    };
    for (schemes) |scheme| {
        if (std.mem.startsWith(u8, input, scheme)) return true;
    }
    return false;
}

fn isSecretChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
}

const testing = std.testing;

test "reseedPrevHashFromFile returns zero on empty file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(rt.io, "audit.jsonl", .{ .read = true, .truncate = true });
    defer file.close(rt.io);
    const hash = try reseedPrevHashFromFile(file);
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &hash);
}

test "reseedPrevHashFromFile hashes last complete line including newline" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(rt.io, "audit.jsonl", .{ .read = true, .truncate = true });
    defer file.close(rt.io);
    const content = "line one\nline two\n";
    try file.writeStreamingAll(rt.io, content);

    const hash = try reseedPrevHashFromFile(file);
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("line two\n", &expected, .{});
    try testing.expectEqualSlices(u8, &expected, &hash);
}

test "reseedPrevHashFromFile skips torn trailing write" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(rt.io, "audit.jsonl", .{ .read = true, .truncate = true });
    defer file.close(rt.io);
    const content = "line one\nline two\npartial-no-newline";
    try file.writeStreamingAll(rt.io, content);

    const hash = try reseedPrevHashFromFile(file);
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("line two\n", &expected, .{});
    try testing.expectEqualSlices(u8, &expected, &hash);
}

test "audit HMAC key parser requires exact length" {
    try testing.expectError(error.InvalidHmacKey, parseHmacKeyBytes("short"));
    try testing.expectError(error.InvalidHmacKey, parseHmacKeyBytes("123456789012345678901234567890123"));
    const key = try parseHmacKeyBytes("12345678901234567890123456789012");
    try testing.expectEqual(@as(usize, 32), key.len);
}

test "audit HMAC key permissions reject group/world access" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "hmac.key", .data = "12345678901234567890123456789012" });
    const file = try tmp.dir.openFile(rt.io, "hmac.key", .{ .mode = .read_write });
    defer file.close(rt.io);
    file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o644)) catch return error.SkipZigTest;

    const root = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const key_path = try std.fs.path.join(testing.allocator, &.{ root, "hmac.key" });
    defer testing.allocator.free(key_path);

    try testing.expectError(error.InsecureHmacKeyPermissions, validateHmacKeyFilePermissions(key_path));
    try file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600));
    try validateHmacKeyFilePermissions(key_path);
}

test "audit HMAC key loader rejects malformed existing key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "hmac.key", .data = "short" });
    const file = try tmp.dir.openFile(rt.io, "hmac.key", .{ .mode = .read_write });
    defer file.close(rt.io);
    file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch return error.SkipZigTest;

    const root = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(root);

    try testing.expectError(error.InvalidHmacKey, loadHmacKeyReadOnly(testing.allocator, root));
    try testing.expectError(error.InvalidHmacKey, loadOrCreateHmacKey(testing.allocator, root));
}

test "redactSecrets strips JSON fields matching sensitive key names" {
    const allocator = testing.allocator;

    // Provider-specific token without a known prefix is redacted when
    // it sits in a field whose key matches the heuristic.
    const ds = "{\"api_key\":\"DeepSeek-aBcDeFgHiJkL\", \"other\":\"ok\"}";
    const r1 = try redactSecrets(allocator, ds);
    defer allocator.free(r1);
    try testing.expect(std.mem.indexOf(u8, r1, "DeepSeek-aBcDeFgHiJkL") == null);
    try testing.expect(std.mem.indexOf(u8, r1, "\"api_key\":\"[REDACTED]\"") != null);
    // Non-sensitive field is preserved.
    try testing.expect(std.mem.indexOf(u8, r1, "\"other\":\"ok\"") != null);

    // Case-insensitive match on the key name.
    const cap = "{\"Authorization\":\"Bearer xyz-123-something-secret-longenough\"}";
    const r2 = try redactSecrets(allocator, cap);
    defer allocator.free(r2);
    try testing.expect(std.mem.indexOf(u8, r2, "xyz-123-something") == null);

    // Whitespace between colon and value is tolerated.
    const ws = "{\"secret\": \"hidden-12345\"}";
    const r3 = try redactSecrets(allocator, ws);
    defer allocator.free(r3);
    try testing.expect(std.mem.indexOf(u8, r3, "hidden-12345") == null);
}

test "redactPromptBodies strips prompt-like fields but preserves metadata" {
    const allocator = testing.allocator;
    const sample =
        \\{"method":"run","prompt":"secret customer prompt","tokens":42,"patch":"diff body"}
    ;
    const redacted = try redactPromptBodies(allocator, sample);
    defer allocator.free(redacted);

    try testing.expect(std.mem.indexOf(u8, redacted, "secret customer prompt") == null);
    try testing.expect(std.mem.indexOf(u8, redacted, "\"prompt\":\"[REDACTED-BODY]\"") != null);
    try testing.expect(std.mem.indexOf(u8, redacted, "\"method\":\"run\"") != null);
    try testing.expect(std.mem.indexOf(u8, redacted, "\"tokens\":42") != null);
}

test "redacts api-like keys" {
    const allocator = testing.allocator;
    const sample = "token=" ++ "sk" ++ "-" ++ "demo" ++ "Secret" ++ "123" ++ " done";
    const redacted = try redactSecrets(allocator, sample);
    defer allocator.free(redacted);

    try testing.expect(std.mem.indexOf(u8, redacted, "demoSecret") == null);
    try testing.expect(std.mem.indexOf(u8, redacted, "[REDACTED]") != null);
}

test "redacts GitHub personal access tokens" {
    const allocator = testing.allocator;
    const sample = "auth=" ++ "gh" ++ "p_" ++ "demoToken" ++ "1234567890" ++ " done";
    const redacted = try redactSecrets(allocator, sample);
    defer allocator.free(redacted);

    try testing.expect(std.mem.indexOf(u8, redacted, "1234567890") == null);
    try testing.expect(std.mem.indexOf(u8, redacted, "[REDACTED]") != null);
}

test "redacts AWS access key IDs" {
    const allocator = testing.allocator;
    const sample = "key=" ++ "AK" ++ "IA" ++ "DEMO" ++ "KEY" ++ "1234" ++ " done";
    const redacted = try redactSecrets(allocator, sample);
    defer allocator.free(redacted);

    try testing.expect(std.mem.indexOf(u8, redacted, "DEMOKEY") == null);
    try testing.expect(std.mem.indexOf(u8, redacted, "[REDACTED]") != null);
}

test "redacts generic long tokens with mixed case and digits" {
    const allocator = testing.allocator;
    const sample = "token=" ++ "aB3cD" ++ "4eF5g" ++ "H6iJ7" ++ "kL8mN" ++ "9oP0q" ++ " done";
    const redacted = try redactSecrets(allocator, sample);
    defer allocator.free(redacted);

    try testing.expect(std.mem.indexOf(u8, redacted, "aB3cD4eF5") == null);
    try testing.expect(std.mem.indexOf(u8, redacted, "[REDACTED]") != null);
}

test "preserves short non-secret strings" {
    const allocator = testing.allocator;
    const redacted = try redactSecrets(allocator, "hello world 123");
    defer allocator.free(redacted);

    try testing.expectEqualStrings("hello world 123", redacted);
}

test "preserves normal long strings without mixed case and digits" {
    const allocator = testing.allocator;
    const redacted = try redactSecrets(allocator, "this_is_a_normal_function_name_that_is_long");
    defer allocator.free(redacted);

    try testing.expectEqualStrings("this_is_a_normal_function_name_that_is_long", redacted);
}

test "redacts Stripe live keys" {
    const allocator = testing.allocator;
    const sample = "key=" ++ "sk" ++ "_live_" ++ "abc" ++ "DEF" ++ "123456" ++ "xyz";
    const redacted = try redactSecrets(allocator, sample);
    defer allocator.free(redacted);

    try testing.expect(std.mem.indexOf(u8, redacted, "abcDEF") == null);
    try testing.expect(std.mem.indexOf(u8, redacted, "[REDACTED]") != null);
}

test "redacts JWT tokens" {
    const allocator = testing.allocator;
    const sample = "auth=" ++ "ey" ++ "J" ++ "hbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig";
    const redacted = try redactSecrets(allocator, sample);
    defer allocator.free(redacted);

    try testing.expect(std.mem.indexOf(u8, redacted, "hbGciOiJ") == null);
    try testing.expect(std.mem.indexOf(u8, redacted, "[REDACTED]") != null);
}

test "redacts database connection strings" {
    const allocator = testing.allocator;
    const sample = "db=" ++ "post" ++ "gres://" ++ "user:pass@host:5432/db done";
    const redacted = try redactSecrets(allocator, sample);
    defer allocator.free(redacted);

    try testing.expect(std.mem.indexOf(u8, redacted, "user:pass") == null);
    try testing.expect(std.mem.indexOf(u8, redacted, "[REDACTED]") != null);
}

test "redacts SendGrid keys" {
    const allocator = testing.allocator;
    const sample = "key=" ++ "SG" ++ "." ++ "abcDEF" ++ "123456" ++ "xyzABC done";
    const redacted = try redactSecrets(allocator, sample);
    defer allocator.free(redacted);

    try testing.expect(std.mem.indexOf(u8, redacted, "abcDEF") == null);
    try testing.expect(std.mem.indexOf(u8, redacted, "[REDACTED]") != null);
}
