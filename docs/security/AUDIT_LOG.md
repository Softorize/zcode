# zcode audit log

zcode writes a tamper-evident audit log to `~/.zcode/logs/` while any
session is running. The log is intended to survive:

- a malicious user on the same host who gains write access to the log
  file between process restarts,
- accidental truncation or partial flushes,
- replacement of single entries with forged content.

It is NOT a replacement for a centralized SIEM; for enterprise
deployments, ship the log to a remote collector via the control plane.

## Format

One JSON object per line (`JSONL`). Each line contains:

| Field | Type | Meaning |
|---|---|---|
| `ts` | integer | Unix seconds when the entry was written |
| `event` | string | Event type (`tool.call`, `approval.granted`, etc.) |
| `payload` | string | Event payload, already secret-redacted |
| `hmac` | string (hex) | HMAC-SHA256 of `prev_hash || ts || event || payload` |

Where:
- `prev_hash` is the SHA-256 of the previous line (including trailing
  newline). Line 1's `prev_hash` is 32 zero bytes.
- The HMAC key lives at `~/.zcode/logs/hmac.key`, is exactly 32 raw
  bytes, and must be mode `0600`. zcode refuses to start if it cannot
  read/create that key or if group/world has any access to it.

## Rotation and retention

- File name: `audit-<day_bucket>.jsonl` where `day_bucket = unix_ts / 86400`.
- Default retention: **90 days**. Files older than the cutoff are
  deleted on startup.
- Tune via `audit_retention_days` in `config.toml`. Set it to `0`
  to disable audit-log cleanup.

## Integrity model

Because every line's HMAC covers the previous line's hash, you cannot:

- change a line without invalidating every subsequent HMAC, or
- delete a line without the next line failing to chain.

An attacker who forges the HMAC key itself can defeat the chain.
Protect the key file and preserve it when verifying archived logs:

```sh
chmod 600 ~/.zcode/logs/hmac.key
chown $(id -u):$(id -g) ~/.zcode/logs/hmac.key
```

## Redaction

Before hashing, every payload passes through `redactSecrets` which
drops known-shaped secrets (Anthropic, OpenAI, GitHub, AWS, Slack,
Stripe, JWT, PEM private keys, DB connection strings) and any JSON
value under a key named `password`, `token`, `secret`, `credential`,
`api_key`, `auth`, or `authorization`.

If `privacy_redact_prompt_bodies = true` is set in `config.toml`, a
second pass replaces values under prompt-carrying keys (`prompt`,
`text`, `content`, `input`, `output`, `response`, `message`, `body`,
`system`, `user_message`, `assistant_message`) with
`"[REDACTED-BODY]"`. Token counts, tool names, timings, and event
types are preserved so the log remains operationally useful.

## Verification

```sh
zcode audit verify                            # today's log
zcode audit verify ~/.zcode/logs/audit-20566.jsonl   # a specific log
```

Output:

- `OK: N entries verified in <path>.` -- chain is intact from line 1
  to line N.
- `FAIL: chain break at line K: <reason>` -- line K is the first
  tampered or malformed entry; exit code 1.

## Remote shipping

With `control_plane_url` + `control_plane_token` set and
`cloud_telemetry_opt_in = true`, every audit entry is POSTed to the
control plane as it is written. The remote ingest should deduplicate
by `(ts, event, hmac)` and preserve the `hmac` field so auditors can
re-verify the chain after ingest.

## Threat model

| Attack | Caught by |
|---|---|
| Single-line edit | Subsequent HMAC mismatch |
| Line deletion | Next line's `prev_hash` is wrong |
| File truncation after restart | `reseedPrevHashFromFile` chain continues from the last complete line, so any gap produces a break |
| Rollback to older file | `SHA256SUMS` / external archive comparison (operator process) |
| HMAC key theft | Not caught -- protect the file-backed key with filesystem permissions |

## Reporting

Report audit-log anomalies via the channel in `SECURITY.md`.
