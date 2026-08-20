#!/usr/bin/env python3
"""zcode runner (#563).

Mirrors reference_runner.py (#562) but spawns the zcode binary against
the same scenario corpus and captures the same streams (wire + commands)
into the same ADR 0010 fixture format, under scenarios/<name>/zcode/.

zcode's headless mode (`zcode exec --json`) emits a single JSON object
(not a stream). This runner normalizes that into the ADR 0010 wire.jsonl
shape: one 'result' record for the final JSON, plus synthetic records
derived from the tool_calls array so the comparison runner (#564) can
diff against the reference's richer stream.

Usage:
    python3 tools/capture/zcode_runner.py <scenario_name> [--bin <path>]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path


SCENARIOS_ROOT = Path(__file__).resolve().parent.parent.parent / "scenarios"
DEFAULT_BIN = shutil.which("zcode") or os.path.expanduser("~/.local/bin/zcode")


def load_meta(scenario_name: str) -> dict:
    meta_path = SCENARIOS_ROOT / scenario_name / "meta.json"
    if not meta_path.exists():
        raise SystemExit(f"scenario not found: {meta_path}")
    return json.loads(meta_path.read_text(encoding="utf-8"))


def check_env_denylist(meta: dict) -> None:
    denylist = meta.get("seed", {}).get("env_denylist", [])
    leaked = [k for k in denylist if k in os.environ]
    if leaked:
        raise SystemExit(
            f"refusing to start: denylisted env vars are set: {leaked}"
        )


def build_prompt(meta: dict) -> str:
    """Concatenate command inputs into a single prompt for zcode exec."""
    parts = []
    for inp in meta.get("inputs", []):
        if inp.get("type") == "command":
            parts.append(inp["value"])
    return "\n".join(parts)


def spawn_zcode(bin_path: str, meta: dict, prompt: str) -> subprocess.CompletedProcess:
    seed = meta.get("seed", {})
    cwd = seed.get("cwd", os.getcwd())
    env = os.environ.copy()
    env.update(seed.get("env_fixed", {}))

    # Use stream-json mode so zcode's output shape matches the reference's
    # (system:init -> assistant -> result). The single-JSON `exec --json`
    # path emits a different format by design; stream-json is the
    # apples-to-apples comparison path.
    cmd = [bin_path, "--print", "--output-format=stream-json",
           "--input-format=stream-json", "--verbose",
           "--yolo"]
    input_record = {"type": "user", "message": {"role": "user", "content": prompt}}
    input_bytes = (json.dumps(input_record) + "\n").encode("utf-8")
    return subprocess.run(
        cmd,
        input=input_bytes,
        capture_output=True,
        cwd=cwd,
        env=env,
        timeout=meta.get("timeout_ms", 30000) / 1000,
    )


def write_wire(out_dir: Path, stdout_bytes: bytes, stderr_bytes: bytes) -> tuple[int, int]:
    """Write wire.jsonl from zcode's stream-json NDJSON output.

    zcode (in stream-json mode) emits the same event sequence as the
    reference: system:init, assistant, result. Each line is a JSON
    object; we annotate with ts_ms/direction/source for ADR 0010.
    """
    wire_path = out_dir / "wire.jsonl"
    base_ts = int(time.time() * 1000)
    count = 0
    bad = 0
    with open(wire_path, "w", encoding="utf-8") as f:
        for i, line in enumerate(stdout_bytes.decode("utf-8", errors="replace").splitlines()):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                bad += 1
                continue
            obj["ts_ms"] = base_ts + i
            obj["direction"] = "response"
            obj["source"] = "zcode"
            f.write(json.dumps(obj, ensure_ascii=False, sort_keys=True))
            f.write("\n")
            count += 1
        if stderr_bytes.strip():
            f.write(json.dumps({
                "ts_ms": base_ts + count + 1,
                "direction": "stderr",
                "source": "zcode",
                "body": stderr_bytes.decode("utf-8", errors="replace"),
            }, ensure_ascii=False, sort_keys=True))
            f.write("\n")
    return count, bad


def find_result_event(stdout_bytes: bytes) -> dict | None:
    """Find the result event in zcode's stream-json NDJSON output."""
    for line in stdout_bytes.decode("utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("type") == "result":
            return obj
    return None


def write_commands(out_dir: Path, meta: dict, result_event: dict | None) -> int:
    cmds_path = out_dir / "commands.jsonl"
    base_ts = int(time.time() * 1000)
    count = 0
    with open(cmds_path, "w", encoding="utf-8") as f:
        for i, inp in enumerate(meta.get("inputs", [])):
            if inp.get("type") != "command":
                continue
            record = {
                "ts_ms": base_ts + i,
                "command": inp["value"],
                "args": "",
                "stdout": result_event.get("result", "") if result_event else "",
                "stderr": "",
                "exit_code": 0 if result_event and not result_event.get("is_error") else 1,
                "rendered_frames": [],
            }
            f.write(json.dumps(record, ensure_ascii=False, sort_keys=True))
            f.write("\n")
            count += 1
    return count


def write_run_meta(out_dir: Path, bin_path: str, meta: dict, wire_count: int, bad_count: int) -> None:
    version = subprocess.run(
        [bin_path, "version"], capture_output=True, text=True, timeout=10
    ).stdout.strip()
    run_meta = {
        "zcode_binary": bin_path,
        "zcode_version": version,
        "scenario_name": meta["scenario_name"],
        "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "wire_records": wire_count,
        "wire_records_unparseable": bad_count,
    }
    (out_dir / "run_meta.json").write_text(
        json.dumps(run_meta, indent=2, sort_keys=True), encoding="utf-8"
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario_name")
    ap.add_argument("--bin", default=DEFAULT_BIN, help="path to zcode binary")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    meta = load_meta(args.scenario_name)
    check_env_denylist(meta)

    out_dir = SCENARIOS_ROOT / args.scenario_name / "zcode"
    out_dir.mkdir(parents=True, exist_ok=True)

    prompt = build_prompt(meta)
    print(f"[zcode_runner] scenario={args.scenario_name} bin={args.bin}")
    print(f"[zcode_runner] cwd={meta.get('seed', {}).get('cwd')}")
    print(f"[zcode_runner] prompt bytes={len(prompt)}")

    if args.dry_run:
        print("[zcode_runner] dry-run: not spawning")
        return 0

    try:
        completed = spawn_zcode(args.bin, meta, prompt)
    except subprocess.TimeoutExpired as e:
        print(f"[zcode_runner] TIMEOUT after {meta.get('timeout_ms', 30000)}ms", file=sys.stderr)
        stdout_bytes = e.stdout or b""
        stderr_bytes = e.stderr or b""
    else:
        stdout_bytes = completed.stdout
        stderr_bytes = completed.stderr

    wire_count, bad_count = write_wire(out_dir, stdout_bytes, stderr_bytes)
    result_event = find_result_event(stdout_bytes)
    cmd_count = write_commands(out_dir, meta, result_event)
    write_run_meta(out_dir, args.bin, meta, wire_count, bad_count)

    print(f"[zcode_runner] wire records: {wire_count} ({bad_count} unparseable)")
    print(f"[zcode_runner] command records: {cmd_count}")
    print(f"[zcode_runner] output: {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
