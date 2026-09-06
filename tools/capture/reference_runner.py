#!/usr/bin/env python3
"""Reference runner (#562).

Spawns the installed `claude` binary against a scenario from the corpus
(ADR 0010), captures wire output + command I/O into the fixture format,
and writes them under scenarios/<name>/reference/.

The installed `claude` binary is the authoritative behavioral oracle
(see ADR 0010 "Reference oracle"). The leaked TS source is NOT run.

Usage:
    python3 tools/capture/reference_runner.py <scenario_name> [--bin <path>]
    python3 tools/capture/reference_runner.py <scenario_name> --pty [--bin <path>]

Reads:  scenarios/<scenario_name>/meta.json
Writes: scenarios/<scenario_name>/reference/{wire.jsonl,commands.jsonl,meta.json}
        (frames.bin is captured by the PTY recorder, not this runner; for
        non-PTY scenarios the reference runner covers the wire + command
        streams only.)

r3-mock-02 follow-up: `--pty` drives a UX-class scenario (docs/capture/
scenario_corpus.md #9-10, e.g. ux-spinner-basic) against the real
interactive `claude` binary over a PTY -- mirroring zcode_runner.py's
`--pty` mode -- and writes scenarios/<name>/reference/{frames.bin,meta.json}
so compare.py has both sides of a genuine frame diff instead of reporting
`zcode_only_capture`. This spends real API usage against the caller's
`claude` account/subscription (an actual model turn runs), so it is not
invoked by `zig build test` or any CI path -- it is a manual, opt-in
recapture step for whoever maintains the corpus, same as reference_runner's
existing headless mode already implies (it also makes a real API call).
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


def _pty_trust_cwd(bin_path: str, cwd: str, env: dict) -> None:
    """Pre-trust `cwd` under the isolated HOME so the interactive first-run
    workspace-trust dialog never blocks the capture waiting for a keypress
    this runner does not know how to answer. The reference binary's own
    `--help` documents that the trust dialog is skipped in non-interactive
    mode ("-p, --print ... The workspace trust dialog is skipped when Claude
    is run in non-interactive mode"), so a throwaway headless call under the
    same HOME records the directory as trusted before the interactive PTY
    session starts -- mirroring zcode_runner.py's `_pty_trust_cwd` (which
    uses zcode's own `trust allow` subcommand instead, since zcode's trust
    store isn't keyed off -p)."""
    try:
        subprocess.run(
            [bin_path, "-p", "--output-format=json", "--dangerously-skip-permissions", "ok"],
            cwd=cwd,
            env=env,
            capture_output=True,
            timeout=30,
        )
    except (subprocess.TimeoutExpired, OSError) as e:
        print(f"[reference_runner] warning: pre-trust of {cwd} failed: {e}", file=sys.stderr)


def run_pty_scenario(bin_path: str, meta: dict, out_dir: Path) -> int:
    """r3-mock-02 follow-up: drive a UX-class scenario over a real PTY
    against the installed `claude` binary and write scenarios/<name>/
    reference/{frames.bin,meta.json}, mirroring zcode_runner.py's
    run_pty_scenario so compare.py's frame_diff can genuinely diff both
    sides instead of reporting `zcode_only_capture`.

    Spends one real model turn against the caller's Claude Code
    account/subscription -- this is a deliberate, manual recapture step,
    not something `zig build test` or CI ever calls.
    """
    seed = meta.get("seed", {})
    fixture_cwd = pty_capture.resolve_seed_cwd(meta)
    if not os.path.isdir(fixture_cwd):
        raise SystemExit(f"scenario cwd does not exist: {fixture_cwd}")
    cwd = fixture_cwd

    fixture_workdir: str | None = None
    if seed.get("git_repo"):
        cwd = pty_capture.prepare_git_fixture(cwd)
        fixture_workdir = cwd

    cols = seed.get("terminal_size", {}).get("cols", 110)
    rows = seed.get("terminal_size", {}).get("rows", 36)

    env = os.environ.copy()
    env.update(seed.get("env_fixed", {}))
    env["TERM"] = env.get("TERM", "xterm-256color")
    env["COLUMNS"] = str(cols)
    env["LINES"] = str(rows)

    cmd = pty_capture.build_interactive_command("reference", bin_path, meta)
    timeout_s = meta.get("timeout_ms", 30000) / 1000.0

    print(f"[reference_runner] scenario={meta.get('scenario_name')} bin={bin_path} mode=pty")
    print(f"[reference_runner] cwd={cwd} size={cols}x{rows}")

    try:
        # A per-run scratch HOME (outside scenarios/, never committed) so the
        # trust state / config the interactive session writes never touches
        # the developer's real ~/.claude and never lands in the captured
        # fixture.
        with tempfile.TemporaryDirectory(prefix="claude-pty-home-") as home:
            env["HOME"] = home
            env["CLAUDE_CONFIG_DIR"] = os.path.join(home, ".claude")
            _pty_trust_cwd(bin_path, cwd, env)
            frames = pty_capture.run_interactive(
                cmd, cwd, env, meta.get("inputs", []), timeout_s, cols=cols, rows=rows
            )
    finally:
        if fixture_workdir:
            shutil.rmtree(fixture_workdir, ignore_errors=True)

    frame_count = pty_capture.write_frames_multi(out_dir, frames)
    total_bytes = sum(len(c) for _, c in frames)

    version = subprocess.run([bin_path, "--version"], capture_output=True, text=True, timeout=10).stdout.strip()
    capture_meta = {
        "scenario_name": meta.get("scenario_name"),
        "mode": "pty",
        "reference_binary": bin_path,
        "reference_version": version,
        "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "cwd": fixture_cwd,
        "git_repo_staged": fixture_workdir is not None,
        "terminal_size": {"cols": cols, "rows": rows},
        "inputs_sent": len(meta.get("inputs", [])),
        "frame_count": frame_count,
        "frame_bytes_total": total_bytes,
    }
    (out_dir / "meta.json").write_text(
        json.dumps(capture_meta, indent=2, sort_keys=True), encoding="utf-8"
    )

    print(f"[reference_runner] frames captured: {frame_count} ({total_bytes} bytes)")
    print(f"[reference_runner] output: {out_dir}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario_name")
    ap.add_argument("--bin", default=DEFAULT_BIN, help="path to claude binary")
    ap.add_argument("--dry-run", action="store_true", help="print plan, don't spawn")
    ap.add_argument(
        "--pty",
        action="store_true",
        help="drive an interactive (fullscreen REPL) scenario over a real PTY "
        "against the installed claude binary instead of the headless -p path "
        "(r3-mock-02 follow-up; needed for the UX-class scenarios in "
        "docs/capture/scenario_corpus.md, e.g. ux-spinner-basic, "
        "ux-permission-prompt). Spends real API usage.",
    )
    args = ap.parse_args()

    meta = load_meta(args.scenario_name)
    check_env_denylist(meta)

    out_dir = SCENARIOS_ROOT / args.scenario_name / "reference"
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.pty:
        if args.dry_run:
            print(f"[reference_runner] scenario={args.scenario_name} bin={args.bin} mode=pty")
            print(f"[reference_runner] cwd={pty_capture.resolve_seed_cwd(meta)}")
            print(f"[reference_runner] inputs={len(meta.get('inputs', []))}")
            print("[reference_runner] dry-run: not spawning")
            return 0
        return run_pty_scenario(args.bin, meta, out_dir)

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
