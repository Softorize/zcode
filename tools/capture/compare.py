#!/usr/bin/env python3
"""Comparison runner (#564).

Takes a reference fixture and a zcode fixture for the same scenario,
diffs them stream-by-stream, and produces a machine-readable diff
report (diff.json) per ADR 0010.

Handles the structural asymmetry between the reference's rich stream
(hook_started, hook_response, init, assistant, result) and zcode's
normalized subset (assistant, result). The diff focuses on fields
both sides share; reference-only fields are reported as
'reference_only_events' rather than failures.

Diffs:
- Wire JSON: structural (key-reorder tolerant), focused on
  assistant.content text and result.result text.
- Command I/O: structured diff on command + stdout + exit_code.
- Frames: not yet diffed (frames.bin is not captured by #562/#563);
  reported as 'not_captured'.

Usage:
    python3 tools/capture/compare.py <scenario_name>
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path


SCENARIOS_ROOT = Path(__file__).resolve().parent.parent.parent / "scenarios"


def load_wire(side: str, scenario_name: str) -> list[dict]:
    path = SCENARIOS_ROOT / scenario_name / side / "wire.jsonl"
    if not path.exists():
        return []
    records = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            records.append(json.loads(line))
    return records


def load_commands(side: str, scenario_name: str) -> list[dict]:
    path = SCENARIOS_ROOT / scenario_name / side / "commands.jsonl"
    if not path.exists():
        return []
    records = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            records.append(json.loads(line))
    return records


def extract_assistant_text(records: list[dict]) -> str | None:
    """Extract the assistant's text response from wire records."""
    for r in records:
        if r.get("type") == "assistant":
            content = r.get("message", {}).get("content", [])
            texts = [c.get("text", "") for c in content if c.get("type") == "text"]
            return "".join(texts)
    return None


def extract_result(records: list[dict]) -> dict | None:
    """Extract the final result record from wire records."""
    for r in reversed(records):
        if r.get("type") == "result":
            return r
    return None


def diff_wire(ref_records: list[dict], zcode_records: list[dict]) -> dict:
    """Structural diff of wire records focused on observable behavior."""
    ref_text = extract_assistant_text(ref_records)
    zcode_text = extract_assistant_text(zcode_records)

    ref_result = extract_result(ref_records)
    zcode_result = extract_result(zcode_records)

    diffs = []

    # Assistant text comparison
    if ref_text is not None and zcode_text is not None:
        if ref_text.strip() != zcode_text.strip():
            diffs.append({
                "field": "assistant.content.text",
                "reference": ref_text,
                "zcode": zcode_text,
                "kind": "value_mismatch",
            })
        else:
            diffs.append({
                "field": "assistant.content.text",
                "kind": "match",
            })
    elif ref_text is None and zcode_text is None:
        diffs.append({"field": "assistant.content.text", "kind": "both_absent"})
    else:
        diffs.append({
            "field": "assistant.content.text",
            "reference": ref_text,
            "zcode": zcode_text,
            "kind": "presence_mismatch",
        })

    # Result comparison
    if ref_result and zcode_result:
        ref_success = not ref_result.get("is_error", False)
        zcode_success = not zcode_result.get("is_error", False)
        if ref_success != zcode_success:
            diffs.append({
                "field": "result.is_error",
                "reference": ref_result.get("is_error"),
                "zcode": zcode_result.get("is_error"),
                "kind": "value_mismatch",
            })
        else:
            diffs.append({"field": "result.is_error", "kind": "match"})

        ref_result_text = ref_result.get("result", "")
        zcode_result_text = zcode_result.get("result", "")
        if ref_result_text.strip() != zcode_result_text.strip():
            diffs.append({
                "field": "result.result",
                "reference": ref_result_text,
                "zcode": zcode_result_text,
                "kind": "value_mismatch",
            })
        else:
            diffs.append({"field": "result.result", "kind": "match"})
    else:
        diffs.append({
            "field": "result",
            "reference_present": ref_result is not None,
            "zcode_present": zcode_result is not None,
            "kind": "presence_mismatch",
        })

    # Reference-only event types (not a failure, just asymmetry)
    ref_types = {r.get("type") for r in ref_records if r.get("type") is not None}
    zcode_types = {r.get("type") for r in zcode_records if r.get("type") is not None}
    reference_only = sorted(ref_types - zcode_types)
    zcode_only = sorted(zcode_types - ref_types)

    return {
        "reference_records": len(ref_records),
        "zcode_records": len(zcode_records),
        "reference_only_event_types": reference_only,
        "zcode_only_event_types": zcode_only,
        "field_diffs": diffs,
        "matches": sum(1 for d in diffs if d.get("kind") == "match"),
        "mismatches": sum(1 for d in diffs if d.get("kind") in ("value_mismatch", "presence_mismatch")),
    }


def diff_commands(ref_cmds: list[dict], zcode_cmds: list[dict]) -> dict:
    """Structured diff of command I/O."""
    if len(ref_cmds) != len(zcode_cmds):
        return {
            "reference_commands": len(ref_cmds),
            "zcode_commands": len(zcode_cmds),
            "kind": "count_mismatch",
            "commands_matched": 0,
            "commands_differed": max(len(ref_cmds), len(zcode_cmds)),
        }

    matched = 0
    differed = 0
    pair_diffs = []
    for i, (ref_cmd, zcode_cmd) in enumerate(zip(ref_cmds, zcode_cmds)):
        ref_out = ref_cmd.get("stdout", "").strip()
        zcode_out = zcode_cmd.get("stdout", "").strip()
        ref_exit = ref_cmd.get("exit_code")
        zcode_exit = zcode_cmd.get("exit_code")
        if ref_out == zcode_out and ref_exit == zcode_exit:
            matched += 1
        else:
            differed += 1
            pair_diffs.append({
                "index": i,
                "command": ref_cmd.get("command"),
                "reference_stdout": ref_out,
                "zcode_stdout": zcode_out,
                "reference_exit": ref_exit,
                "zcode_exit": zcode_exit,
            })

    return {
        "reference_commands": len(ref_cmds),
        "zcode_commands": len(zcode_cmds),
        "commands_matched": matched,
        "commands_differed": differed,
        "pair_diffs": pair_diffs,
    }


def read_frames(path: Path) -> list[bytes]:
    """Read a frames.bin file (ADR 0010 length-prefixed format)."""
    if not path.exists():
        return []
    frames = []
    with open(path, "rb") as f:
        while True:
            header = f.read(8)
            if len(header) < 8:
                break
            ts_ms, frame_len = struct.unpack(">II", header)
            content = f.read(frame_len)
            frames.append(content)
    return frames


def strip_ansi(data: bytes) -> str:
    """Strip ANSI escape sequences to get visible text only."""
    import re
    text = data.decode("utf-8", errors="replace")
    # CSI sequences: \x1b[ ... final byte (0x40-0x7E)
    text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text)
    # OSC sequences: \x1b] ... \x1b\\ or BEL
    text = re.sub(r"\x1b\][^\x1b]*(?:\x1b\\|\x07)", "", text)
    # Other ESC sequences (single-char after ESC)
    text = re.sub(r"\x1b[^[\]]", "", text)
    return text


def diff_frames(scenario_name: str) -> dict:
    """Diff the captured frames.bin between reference and zcode."""
    ref_frames = SCENARIOS_ROOT / scenario_name / "reference" / "frames.bin"
    zcode_frames = SCENARIOS_ROOT / scenario_name / "zcode" / "frames.bin"

    if not ref_frames.exists() or not zcode_frames.exists():
        return {
            "reference_frames_present": ref_frames.exists(),
            "zcode_frames_present": zcode_frames.exists(),
            "kind": "not_captured",
            "note": "frames.bin missing for one or both sides",
        }

    ref = read_frames(ref_frames)
    zcode = read_frames(zcode_frames)

    ref_text = strip_ansi(b"\n".join(ref))
    zcode_text = strip_ansi(b"\n".join(zcode))

    # Normalize trailing whitespace per line for comparison.
    ref_lines = [ln.rstrip() for ln in ref_text.splitlines()]
    zcode_lines = [ln.rstrip() for ln in zcode_text.splitlines()]

    # Find common lines and differing lines.
    ref_set = set(ref_lines)
    zcode_set = set(zcode_lines)
    common = ref_set & zcode_set
    ref_only = ref_set - zcode_set
    zcode_only = zcode_set - ref_set

    # A "visible match" means the non-empty lines that appear in both.
    ref_nonempty = [ln for ln in ref_lines if ln.strip()]
    zcode_nonempty = [ln for ln in zcode_lines if ln.strip()]
    matched = sum(1 for ln in ref_nonempty if ln in zcode_set)
    differed = len(ref_nonempty) - matched

    return {
        "reference_frames_present": True,
        "zcode_frames_present": True,
        "reference_frame_count": len(ref),
        "zcode_frame_count": len(zcode),
        "reference_visible_lines": len(ref_nonempty),
        "zcode_visible_lines": len(zcode_nonempty),
        "lines_matched": matched,
        "lines_differed": differed,
        "reference_only_lines": sorted(ref_only)[:20],
        "zcode_only_lines": sorted(zcode_only)[:20],
        "kind": "diffed",
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario_name")
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 if any mismatch is found")
    args = ap.parse_args()

    ref_wire = load_wire("reference", args.scenario_name)
    zcode_wire = load_wire("zcode", args.scenario_name)
    ref_cmds = load_commands("reference", args.scenario_name)
    zcode_cmds = load_commands("zcode", args.scenario_name)

    wire_diff = diff_wire(ref_wire, zcode_wire)
    cmd_diff = diff_commands(ref_cmds, zcode_cmds)
    frame_diff = diff_frames(args.scenario_name)

    diff_report = {
        "scenario_name": args.scenario_name,
        "wire_diff": wire_diff,
        "command_diff": cmd_diff,
        "frame_diff": frame_diff,
    }

    out_path = SCENARIOS_ROOT / args.scenario_name / "diff.json"
    out_path.write_text(
        json.dumps(diff_report, indent=2, sort_keys=True, ensure_ascii=False),
        encoding="utf-8",
    )

    print(f"[compare] scenario={args.scenario_name}")
    print(f"[compare] wire: {wire_diff['matches']} matches, {wire_diff['mismatches']} mismatches")
    print(f"[compare] commands: {cmd_diff['commands_matched']} matched, {cmd_diff['commands_differed']} differed")
    print(f"[compare] frames: {frame_diff['kind']}")
    print(f"[compare] output: {out_path}")

    if args.strict and (wire_diff["mismatches"] > 0 or cmd_diff["commands_differed"] > 0):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
