#!/usr/bin/env python3
"""Round-trip proof for the ADR 0010 capture fixture format.

Creates a hand-crafted example of each stream type (wire, frames,
commands) under a temp scenario directory, reads them back, and
asserts equality. This satisfies the #561 acceptance criterion:
"Format round-trips a hand-crafted example of each stream type."

Does NOT depend on the reference or zcode being runnable. Pure format
proof.
"""

import json
import os
import struct
import sys
import tempfile
from pathlib import Path


def write_wire(path: Path, records: list[dict]) -> None:
    with open(path, "w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(r, ensure_ascii=False, sort_keys=True))
            f.write("\n")


def read_wire(path: Path) -> list[dict]:
    out = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            out.append(json.loads(line))
    return out


def write_frames(path: Path, frames: list[dict]) -> None:
    """frames: list of {ts_ms, content (str with ANSI escapes)}."""
    with open(path, "wb") as f:
        for fr in frames:
            content_bytes = fr["content"].encode("utf-8")
            f.write(struct.pack(">II", fr["ts_ms"], len(content_bytes)))
            f.write(content_bytes)


def read_frames(path: Path) -> list[dict]:
    out = []
    with open(path, "rb") as f:
        while True:
            header = f.read(8)
            if len(header) < 8:
                break
            ts_ms, frame_len = struct.unpack(">II", header)
            content = f.read(frame_len).decode("utf-8")
            out.append({"ts_ms": ts_ms, "content": content})
    return out


def write_commands(path: Path, records: list[dict]) -> None:
    with open(path, "w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(r, ensure_ascii=False, sort_keys=True))
            f.write("\n")


def read_commands(path: Path) -> list[dict]:
    out = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            out.append(json.loads(line))
    return out


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        scenario_dir = Path(tmp) / "command-commit-basic"
        (scenario_dir / "reference").mkdir(parents=True)

        meta = {
            "scenario_name": "command-commit-basic",
            "scenario_class": "command",
            "description": "proof of concept",
            "seed": {
                "cwd": "/tmp/zcode-fixtures/repo-clean-staged",
                "env_denylist": ["ANTHROPIC_API_KEY"],
                "env_fixed": {"TZ": "UTC"},
                "terminal_size": {"cols": 80, "rows": 24},
            },
            "inputs": [{"type": "command", "value": "/commit"}],
            "timeout_ms": 30000,
        }
        (scenario_dir / "meta.json").write_text(
            json.dumps(meta, indent=2, sort_keys=True), encoding="utf-8"
        )

        wire_records = [
            {
                "ts_ms": 1719038400000,
                "direction": "request",
                "method": "POST",
                "path": "/v1/messages",
                "headers": {"content-type": "application/json"},
                "body": {"model": "claude-sonnet-4-5", "messages": []},
            },
            {
                "ts_ms": 1719038401234,
                "direction": "response",
                "status": 200,
                "headers": {"content-type": "application/json"},
                "body": {"id": "msg_1", "stop_reason": "end_turn"},
            },
        ]
        write_wire(scenario_dir / "reference" / "wire.jsonl", wire_records)

        frames = [
            {"ts_ms": 0, "content": "\x1b[2J\x1b[Hready\r\n"},
            {"ts_ms": 1000, "content": "\x1b[32m>\x1b[0m /commit\r\n"},
            {"ts_ms": 2000, "content": "committed abc1234\r\n"},
        ]
        write_frames(scenario_dir / "reference" / "frames.bin", frames)

        commands = [
            {
                "ts_ms": 1000,
                "command": "/commit",
                "args": "",
                "stdout": "committed abc1234",
                "stderr": "",
                "exit_code": 0,
                "rendered_frames": [1, 2],
            }
        ]
        write_commands(scenario_dir / "reference" / "commands.jsonl", commands)

        # Round-trip
        got_meta = json.loads(
            (scenario_dir / "meta.json").read_text(encoding="utf-8")
        )
        assert got_meta == meta, "meta.json round-trip failed"

        got_wire = read_wire(scenario_dir / "reference" / "wire.jsonl")
        assert got_wire == wire_records, "wire.jsonl round-trip failed"

        got_frames = read_frames(scenario_dir / "reference" / "frames.bin")
        assert got_frames == frames, "frames.bin round-trip failed"

        got_commands = read_commands(scenario_dir / "reference" / "commands.jsonl")
        assert got_commands == commands, "commands.jsonl round-trip failed"

    print("OK: all three stream types round-trip cleanly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
