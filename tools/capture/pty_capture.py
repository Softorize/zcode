#!/usr/bin/env python3
"""PTY frame capture (#574/#564 enhancement).

Runs a CLI in a pseudo-terminal and captures the rendered ANSI frames.
This is the missing piece for UX pixel-parity: the wire/command
captures from #562/#563 don't capture the on-screen render. This tool
spawns the binary in a PTY, feeds a scenario's inputs, and records the
final terminal frame.

Two modes:
  reference: spawn `claude -p ...` (the installed reference oracle)
  zcode:     spawn `zcode exec --json ...`

Usage:
    python3 tools/capture/pty_capture.py <scenario_name> --mode <reference|zcode>

Writes: scenarios/<name>/<mode>/frames.bin (ADR 0010 frame format:
[4 bytes ts_ms][4 bytes frame_len][frame bytes]...).

NOTE: interactive slash-command capture (the kind that needs a live
REPL with keyboard input) is the hard case. This tool handles the
headless -p path first; interactive PTY scripting (via expect-style
keystroke injection) is a follow-up.
"""

from __future__ import annotations

import argparse
import json
import os
import pty
import select
import shutil
import struct
import sys
import time
from pathlib import Path


SCENARIOS_ROOT = Path(__file__).resolve().parent.parent.parent / "scenarios"
DEFAULT_REF_BIN = shutil.which("claude") or "/Users/example/.local/bin/claude"
DEFAULT_ZCODE_BIN = shutil.which("zcode") or os.path.expanduser("~/.local/bin/zcode")


def load_meta(scenario_name: str) -> dict:
    meta_path = SCENARIOS_ROOT / scenario_name / "meta.json"
    if not meta_path.exists():
        raise SystemExit(f"scenario not found: {meta_path}")
    return json.loads(meta_path.read_text(encoding="utf-8"))


def build_command(mode: str, bin_path: str, meta: dict) -> list[str]:
    prompt_parts = []
    for inp in meta.get("inputs", []):
        if inp.get("type") == "command":
            prompt_parts.append(inp["value"])
    prompt = "\n".join(prompt_parts)

    if mode == "reference":
        return [bin_path, "-p", "--output-format=stream-json",
                "--input-format=stream-json", "--verbose",
                "--dangerously-skip-permissions"]
        # Note: the reference reads stream-json from stdin; we feed it separately.
    elif mode == "zcode":
        return [bin_path, "exec", "--json", prompt]
    else:
        raise SystemExit(f"unknown mode: {mode}")


def build_stdin(meta: dict) -> bytes:
    """Build stream-json stdin for the reference; empty for zcode."""
    lines = []
    for inp in meta.get("inputs", []):
        if inp.get("type") == "command":
            record = {"type": "user", "message": {"role": "user", "content": inp["value"]}}
            lines.append(json.dumps(record))
    return ("\n".join(lines) + "\n").encode("utf-8") if lines else b""


def spawn_pty(cmd: list[str], cwd: str, env: dict, stdin_bytes: bytes,
              timeout_s: float) -> tuple[bytes, bytes]:
    """Spawn cmd in a PTY, feed stdin, capture stdout+stderr. Returns (out, err)."""
    cols = 80
    rows = 24
    pid, fd = pty.fork()
    if pid == 0:
        # child
        try:
            os.chdir(cwd)
            for k, v in env.items():
                os.environ[k] = v
            # set window size
            import fcntl
            import termios
            winsize = struct.pack("HHHH", rows, cols, 0, 0)
            fcntl.ioctl(0, termios.TIOCSWINSZ, winsize)
            os.execvp(cmd[0], cmd)
        except Exception:
            os._exit(127)
        os._exit(127)

    # parent
    output = bytearray()
    if stdin_bytes:
        try:
            os.write(fd, stdin_bytes)
        except OSError:
            pass
    start = time.time()
    while True:
        if time.time() - start > timeout_s:
            break
        r, _, _ = select.select([fd], [], [], 0.2)
        if fd in r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            output.extend(data)
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.waitpid(pid, os.WNOHANG)
    except OSError:
        pass
    return bytes(output), b""


def write_frames(out_dir: Path, raw_output: bytes) -> int:
    """Write frames.bin: a single frame containing the raw PTY output."""
    frames_path = out_dir / "frames.bin"
    # Use ms-since-epoch mod 2^32 to fit u32 (ADR 0010 uses u32 ts_ms).
    ts_ms = int(time.time() * 1000) % (2**32)
    with open(frames_path, "wb") as f:
        f.write(struct.pack(">II", ts_ms, len(raw_output)))
        f.write(raw_output)
    return 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario_name")
    ap.add_argument("--mode", choices=["reference", "zcode"], required=True)
    ap.add_argument("--bin", default=None)
    ap.add_argument("--timeout", type=float, default=60.0)
    args = ap.parse_args()

    meta = load_meta(args.scenario_name)
    bin_path = args.bin or (
        DEFAULT_REF_BIN if args.mode == "reference" else DEFAULT_ZCODE_BIN
    )

    out_dir = SCENARIOS_ROOT / args.scenario_name / args.mode
    out_dir.mkdir(parents=True, exist_ok=True)

    cmd = build_command(args.mode, bin_path, meta)
    stdin_bytes = build_stdin(meta) if args.mode == "reference" else b""
    seed = meta.get("seed", {})
    cwd = seed.get("cwd", "/tmp")
    env = os.environ.copy()
    env.update(seed.get("env_fixed", {}))

    print(f"[pty_capture] mode={args.mode} bin={bin_path} cmd={' '.join(cmd[:3])}...")
    print(f"[pty_capture] cwd={cwd} stdin_bytes={len(stdin_bytes)}")

    try:
        out, err = spawn_pty(cmd, cwd, env, stdin_bytes, args.timeout)
    except Exception as e:
        print(f"[pty_capture] spawn failed: {e}", file=sys.stderr)
        return 1

    frame_count = write_frames(out_dir, out)
    print(f"[pty_capture] captured {len(out)} bytes as {frame_count} frame(s)")
    print(f"[pty_capture] output: {out_dir}/frames.bin")
    return 0


if __name__ == "__main__":
    sys.exit(main())
