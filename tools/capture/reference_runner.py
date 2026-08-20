#!/usr/bin/env python3
"""Reference runner (#562).

Spawns the installed `claude` binary against a scenario from the corpus
(ADR 0010), captures wire output + command I/O into the fixture format,
and writes them under scenarios/<name>/reference/.

The installed `claude` binary is the authoritative behavioral oracle
(see ADR 0010 "Reference oracle"). The leaked TS source is NOT run.

Usage:
    python3 tools/capture/reference_runner.py <scenario_name> [--bin <path>]

Reads:  scenarios/<scenario_name>/meta.json
Writes: scenarios/<scenario_name>/reference/{wire.jsonl,commands.jsonl,meta.json}
        (frames.bin is captured by the PTY recorder, not this runner; for
        non-PTY scenarios the reference runner covers the wire + command
        streams only.)
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
DEFAULT_BIN = shutil.which("claude") or "claude"


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


def build_input_stream(meta: dict) -> bytes:
    """Build the stream-json input for the reference.

    Each 'command' input becomes a JSON user-message record. 'keystroke'
    inputs are ignored for headless capture (they apply to interactive
    scenarios handled by the PTY recorder, not this runner).
    """
    lines = []
    for inp in meta.get("inputs", []):
        if inp.get("type") == "command":
            # The 'value' for a command input is the user prompt to send.
            # For slash commands, the reference treats them as user text
            # in headless mode (it parses /commands from input).
            record = {
                "type": "user",
                "message": {"role": "user", "content": inp["value"]},
            }
            lines.append(json.dumps(record, ensure_ascii=False))
    return ("\n".join(lines) + "\n").encode("utf-8") if lines else b""


def spawn_reference(
    bin_path: str, meta: dict, input_bytes: bytes
) -> subprocess.CompletedProcess:
    """Spawn the reference with stream-json I/O."""
    seed = meta.get("seed", {})
    cwd = seed.get("cwd", os.getcwd())
    env = os.environ.copy()
    env.update(seed.get("env_fixed", {}))
    # Force deterministic terminal behavior in headless mode.
    env.setdefault("CLAUDE_CODE_DISABLE_NONINTERACTIVE_CONSOLE", "1")

    cmd = [
        bin_path,
        "-p",
        "--output-format=stream-json",
        "--input-format=stream-json",
        "--verbose",
        "--dangerously-skip-permissions",  # headless capture must not block
    ]
    if meta.get("scenario_class") == "command":
        # For command scenarios, send the command as the prompt directly.
        pass

    return subprocess.run(
        cmd,
        input=input_bytes,
        capture_output=True,
        cwd=cwd,
        env=env,
        timeout=meta.get("timeout_ms", 30000) / 1000,
    )


def write_wire(out_dir: Path, stdout_bytes: bytes, stderr_bytes: bytes) -> tuple[int, int]:
    """Write wire.jsonl from the reference's stream-json stdout.

    Each line is already a JSON object; we augment with a ts_ms and
    direction field to match ADR 0010's wire.jsonl shape.
    """
    wire_path = out_dir / "wire.jsonl"
    count = 0
    bad = 0
    base_ts = int(time.time() * 1000)
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
            # Annotate to match ADR 0010 wire.jsonl shape.
            obj["ts_ms"] = base_ts + i
            obj["direction"] = "response"
            obj["source"] = "reference"
            f.write(json.dumps(obj, ensure_ascii=False, sort_keys=True))
            f.write("\n")
            count += 1
        # If stderr captured anything interesting, record it as a final wire event.
        if stderr_bytes.strip():
            f.write(json.dumps({
                "ts_ms": base_ts + count + 1,
                "direction": "stderr",
                "source": "reference",
                "body": stderr_bytes.decode("utf-8", errors="replace"),
            }, ensure_ascii=False, sort_keys=True))
            f.write("\n")
    return count, bad


def write_commands(out_dir: Path, meta: dict, result_obj: dict | None) -> int:
    """Write commands.jsonl - one record per command input."""
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
                "stdout": result_obj.get("result", "") if result_obj else "",
                "stderr": "",
                "exit_code": 0 if result_obj and not result_obj.get("is_error") else 1,
                "rendered_frames": [],
            }
            f.write(json.dumps(record, ensure_ascii=False, sort_keys=True))
            f.write("\n")
            count += 1
    return count


def write_run_meta(out_dir: Path, bin_path: str, meta: dict, wire_count: int, bad_count: int) -> None:
    """Write a run-meta.json next to the capture for provenance."""
    version = subprocess.run(
        [bin_path, "--version"], capture_output=True, text=True, timeout=10
    ).stdout.strip()
    run_meta = {
        "reference_binary": bin_path,
        "reference_version": version,
        "scenario_name": meta["scenario_name"],
        "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "wire_records": wire_count,
        "wire_records_unparseable": bad_count,
    }
    (out_dir / "run_meta.json").write_text(
        json.dumps(run_meta, indent=2, sort_keys=True), encoding="utf-8"
    )


def find_result_object(stdout_bytes: bytes) -> dict | None:
    """Find the final 'result' JSON object in the stream-json output."""
    for line in reversed(stdout_bytes.decode("utf-8", errors="replace").splitlines()):
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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario_name")
    ap.add_argument("--bin", default=DEFAULT_BIN, help="path to claude binary")
    ap.add_argument("--dry-run", action="store_true", help="print plan, don't spawn")
    args = ap.parse_args()

    meta = load_meta(args.scenario_name)
    check_env_denylist(meta)

    out_dir = SCENARIOS_ROOT / args.scenario_name / "reference"
    out_dir.mkdir(parents=True, exist_ok=True)

    input_bytes = build_input_stream(meta)
    print(f"[reference_runner] scenario={args.scenario_name} bin={args.bin}")
    print(f"[reference_runner] cwd={meta.get('seed', {}).get('cwd')}")
    print(f"[reference_runner] input bytes={len(input_bytes)}")

    if args.dry_run:
        print("[reference_runner] dry-run: not spawning")
        return 0

    try:
        completed = spawn_reference(args.bin, meta, input_bytes)
    except subprocess.TimeoutExpired as e:
        print(f"[reference_runner] TIMEOUT after {meta.get('timeout_ms', 30000)}ms", file=sys.stderr)
        # Still record what we got.
        stdout_bytes = e.stdout or b""
        stderr_bytes = e.stderr or b""
    else:
        stdout_bytes = completed.stdout
        stderr_bytes = completed.stderr

    wire_count, bad_count = write_wire(out_dir, stdout_bytes, stderr_bytes)
    result_obj = find_result_object(stdout_bytes)
    cmd_count = write_commands(out_dir, meta, result_obj)
    write_run_meta(out_dir, args.bin, meta, wire_count, bad_count)

    print(f"[reference_runner] wire records: {wire_count} ({bad_count} unparseable)")
    print(f"[reference_runner] command records: {cmd_count}")
    print(f"[reference_runner] output: {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
