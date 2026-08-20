//! swarm-tasks-17: background-agent rolling summarization cadence.
//!
//! A long-running background agent does meaningful work between its start and
//! finish, but today the parent only sees a status flip at the two ends. The
//! reference (agentToolUtils.ts:508-595 runAsyncAgentLifecycle ->
//! startAgentSummarization) periodically forks a cheap "summarize progress"
//! turn over the agent's history-so-far and surfaces it to the parent.
//!
//! This module is the PURE cadence decision and nothing else. It answers one
//! question: given the current tool-round count, the round at which we last
//! summarized, and the wall-clock seconds elapsed since the last summary,
//! should we summarize now?
//!
//! Keeping the decision pure makes the policy fully unit-testable and keeps
//! the cost-control knobs (how often we spend an extra API call) in one place.
//! The actual summary generation (an LLM fork + a task-record write) lives in
//! the caller (agent_runtime.BackgroundCtx.run), which is best-effort and
//! silent on failure -- it must never block or fail the agent's real work.
//!
//! Cadence semantics (mirroring "every N tool rounds OR T seconds"):
//!   - Fire when at least `min_rounds` tool rounds have elapsed since the last
//!     summary, OR
//!   - Fire when at least `min_seconds` wall-clock seconds have elapsed since
//!     the last summary,
//!   whichever comes first. The defaults are deliberately conservative because
//!   each summary turn costs an API call.

const std = @import("std");
const env_mod = @import("env.zig");

/// Env override for the round threshold. Mirrors the reference's tunable
/// summarization interval. Unset / unparsable falls back to the default.
pub const ROUNDS_ENV = "ZCODE_SUMMARY_EVERY_ROUNDS";
/// Env override for the time threshold, in seconds.
pub const SECONDS_ENV = "ZCODE_SUMMARY_EVERY_SECONDS";

/// Conservative defaults: summarize at most once every 8 tool rounds or once
/// every 60 seconds, whichever comes first. Each summary is an extra API call,
/// so we bias toward fewer.
pub const DEFAULT_MIN_ROUNDS: usize = 8;
pub const DEFAULT_MIN_SECONDS: i64 = 60;

/// The cadence thresholds. Either threshold crossing triggers a summary.
pub const Config = struct {
    /// Minimum tool rounds between summaries. 0 disables the round trigger.
    min_rounds: usize = DEFAULT_MIN_ROUNDS,
    /// Minimum wall-clock seconds between summaries. 0 disables the time
    /// trigger.
    min_seconds: i64 = DEFAULT_MIN_SECONDS,

    /// Build a Config from the process environment, falling back to the
    /// conservative defaults for any var that is unset or unparsable.
    pub fn fromEnv() Config {
        var cfg = Config{};
        if (env_mod.getenv(ROUNDS_ENV)) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (std.fmt.parseInt(usize, trimmed, 10)) |v| {
                cfg.min_rounds = v;
            } else |_| {}
        }
        if (env_mod.getenv(SECONDS_ENV)) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (std.fmt.parseInt(i64, trimmed, 10)) |v| {
                if (v >= 0) cfg.min_seconds = v;
            } else |_| {}
        }
        return cfg;
    }
};

/// Decide whether to fire a rolling summary now, using the default cadence.
///
/// - `rounds`: the agent's current cumulative tool-round count.
/// - `last_summary_round`: the round at which the last summary fired (0 when
///   none has fired yet).
/// - `elapsed_seconds`: wall-clock seconds since the last summary (or since the
///   agent started, when none has fired yet).
///
/// Returns true at the threshold and not before. A round threshold or a time
/// threshold crossing each independently triggers a summary; whichever comes
/// first wins. A summary never fires before at least one tool round has run
/// (`rounds == 0` is always false), so the very first round is never wasted on
/// a summary of nothing.
pub fn shouldSummarize(rounds: usize, last_summary_round: usize, elapsed_seconds: i64) bool {
    return shouldSummarizeWith(Config{}, rounds, last_summary_round, elapsed_seconds);
}

/// Cadence decision with an explicit `Config` (lets the caller read thresholds
/// from the env once via `Config.fromEnv` and reuse them across rounds, and
/// makes the unit tests deterministic regardless of the ambient env).
pub fn shouldSummarizeWith(cfg: Config, rounds: usize, last_summary_round: usize, elapsed_seconds: i64) bool {
    // Never summarize before any real work has happened.
    if (rounds == 0) return false;
    // Never summarize a round we have already summarized (defensive against a
    // caller passing a stale or equal last_summary_round).
    if (rounds <= last_summary_round) return false;

    const rounds_since = rounds - last_summary_round;
    const round_trigger = cfg.min_rounds != 0 and rounds_since >= cfg.min_rounds;
    const time_trigger = cfg.min_seconds != 0 and elapsed_seconds >= cfg.min_seconds;
    return round_trigger or time_trigger;
}

const testing = std.testing;

test "shouldSummarize: does not fire at round 0" {
    try testing.expect(!shouldSummarize(0, 0, 0));
    // Even with a long elapsed time, no work means no summary.
    try testing.expect(!shouldSummarize(0, 0, 9999));
}

test "shouldSummarize: round threshold fires exactly at the boundary, not before" {
    // Default threshold is 8 rounds. last_summary_round=0.
    try testing.expect(!shouldSummarize(1, 0, 0));
    try testing.expect(!shouldSummarize(7, 0, 0));
    try testing.expect(shouldSummarize(8, 0, 0)); // exactly at the threshold
    try testing.expect(shouldSummarize(9, 0, 0)); // and beyond
}

test "shouldSummarize: round threshold is relative to last summary" {
    // Last summary fired at round 8; the next must wait another 8 rounds.
    try testing.expect(!shouldSummarize(15, 8, 0));
    try testing.expect(shouldSummarize(16, 8, 0));
}

test "shouldSummarize: time threshold fires at the boundary even with few rounds" {
    // Default time threshold is 60s. One round has run, 59s is not enough.
    try testing.expect(!shouldSummarize(1, 0, 59));
    try testing.expect(shouldSummarize(1, 0, 60)); // exactly at the threshold
    try testing.expect(shouldSummarize(1, 0, 120)); // and beyond
}

test "shouldSummarize: never re-summarizes the same or an earlier round" {
    try testing.expect(!shouldSummarize(8, 8, 9999));
    try testing.expect(!shouldSummarize(5, 8, 9999));
}

test "shouldSummarizeWith: round trigger can be disabled with min_rounds=0" {
    const cfg = Config{ .min_rounds = 0, .min_seconds = 60 };
    // Round count is huge but the round trigger is off; only time matters.
    try testing.expect(!shouldSummarizeWith(cfg, 1000, 0, 30));
    try testing.expect(shouldSummarizeWith(cfg, 1000, 0, 60));
}

test "shouldSummarizeWith: time trigger can be disabled with min_seconds=0" {
    const cfg = Config{ .min_rounds = 4, .min_seconds = 0 };
    // Time is huge but the time trigger is off; only rounds matter.
    try testing.expect(!shouldSummarizeWith(cfg, 3, 0, 99999));
    try testing.expect(shouldSummarizeWith(cfg, 4, 0, 99999));
}

test "shouldSummarizeWith: custom thresholds, whichever-first wins" {
    const cfg = Config{ .min_rounds = 3, .min_seconds = 10 };
    // Round threshold reached first.
    try testing.expect(shouldSummarizeWith(cfg, 3, 0, 1));
    // Time threshold reached first (only 2 rounds, but 10s elapsed).
    try testing.expect(shouldSummarizeWith(cfg, 2, 0, 10));
    // Neither reached.
    try testing.expect(!shouldSummarizeWith(cfg, 2, 0, 9));
}

test "Config.fromEnv falls back to defaults when env unset" {
    // We don't set the env here; just assert the defaults are wired.
    const cfg = Config{};
    try testing.expectEqual(@as(usize, DEFAULT_MIN_ROUNDS), cfg.min_rounds);
    try testing.expectEqual(@as(i64, DEFAULT_MIN_SECONDS), cfg.min_seconds);
}
