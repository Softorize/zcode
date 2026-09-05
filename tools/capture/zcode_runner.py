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

r3-mock-02 adds a second, interactive mode (`--pty`) for scenarios whose
class is UX (docs/capture/scenario_corpus.md #9-10: ux-permission-prompt,
ux-spinner-basic) -- these need a live fullscreen REPL, not the headless
--print path above, so they drive pty_capture.run_interactive instead and
write frames.bin (+ a per-run meta.json) under the same scenarios/<name>/zcode/
directory.

Usage:
    python3 tools/capture/zcode_runner.py <scenario_name> [--bin <path>]
    python3 tools/capture/zcode_runner.py <scenario_name> --pty [--bin <path>]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pty_capture  # noqa: E402 (needs sys.path tweak above)


SCENARIOS_ROOT = Path(__file__).resolve().parent.parent.parent / "scenarios"
DEFAULT_BIN = shutil.which("zcode") or os.path.expanduser("~/.local/bin/zcode")


def load_meta(scenario_name: str) -> dict:
    meta_path = SCENARIOS_ROOT / scenario_name / "meta.json"
    if not meta_path.exists():
        raise SystemExit(f"scenario not found: {meta_path}")
    return json.loads(meta_path.read_text(encoding="utf-8"))


def resolve_seed_cwd(meta: dict) -> str:
    """Resolve seed.cwd to an absolute path.

    A path already rooted at "/" is used as-is (matches every existing
    scenario, e.g. command-commit-basic's "/tmp"). A scenario that ships its
    own fixture directory (so the capture is self-contained and reproducible
    in CI, not just on the machine that first recorded it) instead names it
    relative to the repo root, e.g. "scenarios/ux-spinner-basic/fixture" --
    resolve that against the repo root (SCENARIOS_ROOT's parent).
    """
    cwd = meta.get("seed", {}).get("cwd", "")
    if not cwd:
        return os.getcwd()
    if os.path.isabs(cwd):
        return cwd
    return str((SCENARIOS_ROOT.parent / cwd).resolve())


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


def _pty_trust_cwd(bin_path: str, cwd: str, env: dict) -> None:
    """Pre-trust `cwd` under the isolated HOME (via `zcode trust allow`) so
    the interactive first-run trust gate never blocks the capture waiting
    for a keypress this runner does not know how to answer."""
    try:
        subprocess.run(
            [bin_path, "trust", "allow", cwd],
            env=env,
            capture_output=True,
            timeout=10,
        )
    except (subprocess.TimeoutExpired, OSError) as e:
        print(f"[zcode_runner] warning: pre-trust of {cwd} failed: {e}", file=sys.stderr)


def run_pty_scenario(bin_path: str, meta: dict, out_dir: Path) -> int:
    """r3-mock-02: drive an interactive scenario over a real PTY and write
    scenarios/<name>/zcode/{frames.bin,meta.json} per ADR 0010's frames.bin
    shape (the top-level scenario meta.json is the scenario's own spec; this
    is a separate, per-run capture-metadata file of the same name living
    under zcode/, mirroring write_run_meta's run_meta.json for the headless
    path above but named to match this gap's acceptance test verbatim).
    """
    seed = meta.get("seed", {})
    cwd = resolve_seed_cwd(meta)
    if not os.path.isdir(cwd):
        raise SystemExit(f"scenario cwd does not exist: {cwd}")

    cols = seed.get("terminal_size", {}).get("cols", 110)
    rows = seed.get("terminal_size", {}).get("rows", 36)

    env = os.environ.copy()
    env.update(seed.get("env_fixed", {}))
    env["TERM"] = env.get("TERM", "xterm-256color")
    env["COLUMNS"] = str(cols)
    env["LINES"] = str(rows)

    cmd = [bin_path, "--provider", seed.get("provider", "mock"), "--model", seed.get("model", "mock-agent")]
    timeout_s = meta.get("timeout_ms", 30000) / 1000.0

    print(f"[zcode_runner] scenario={meta.get('scenario_name')} bin={bin_path} mode=pty")
    print(f"[zcode_runner] cwd={cwd} size={cols}x{rows}")

    # A per-run scratch HOME (outside scenarios/, never committed) so the
    # trust state / config the interactive session writes never touches the
    # developer's real ~/.zcode and never lands in the captured fixture.
    with tempfile.TemporaryDirectory(prefix="zcode-pty-home-") as home:
        env["HOME"] = home
        _pty_trust_cwd(bin_path, cwd, env)
        frames = pty_capture.run_interactive(
            cmd, cwd, env, meta.get("inputs", []), timeout_s, cols=cols, rows=rows
        )

    frame_count = pty_capture.write_frames_multi(out_dir, frames)
    total_bytes = sum(len(c) for _, c in frames)

    version = subprocess.run([bin_path, "version"], capture_output=True, text=True, timeout=10).stdout.strip()
    capture_meta = {
        "scenario_name": meta.get("scenario_name"),
        "mode": "pty",
        "zcode_binary": bin_path,
        "zcode_version": version,
        "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "cwd": cwd,
        "terminal_size": {"cols": cols, "rows": rows},
        "inputs_sent": len(meta.get("inputs", [])),
        "frame_count": frame_count,
        "frame_bytes_total": total_bytes,
    }
    (out_dir / "meta.json").write_text(
        json.dumps(capture_meta, indent=2, sort_keys=True), encoding="utf-8"
    )

    print(f"[zcode_runner] frames captured: {frame_count} ({total_bytes} bytes)")
    print(f"[zcode_runner] output: {out_dir}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario_name")
    ap.add_argument("--bin", default=DEFAULT_BIN, help="path to zcode binary")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument(
        "--pty",
        action="store_true",
        help="drive an interactive (fullscreen REPL) scenario over a real PTY "
        "instead of the headless --print path (r3-mock-02; needed for the "
        "UX-class scenarios in docs/capture/scenario_corpus.md, e.g. "
        "ux-spinner-basic, ux-permission-prompt)",
    )
    args = ap.parse_args()

    meta = load_meta(args.scenario_name)
    check_env_denylist(meta)

    out_dir = SCENARIOS_ROOT / args.scenario_name / "zcode"
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.pty:
        if args.dry_run:
            print(f"[zcode_runner] scenario={args.scenario_name} bin={args.bin} mode=pty")
            print(f"[zcode_runner] cwd={resolve_seed_cwd(meta)}")
            print(f"[zcode_runner] inputs={len(meta.get('inputs', []))}")
            print("[zcode_runner] dry-run: not spawning")
            return 0
        return run_pty_scenario(args.bin, meta, out_dir)

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
