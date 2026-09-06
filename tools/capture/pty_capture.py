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
import subprocess
import sys
import tempfile
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


def resolve_seed_cwd(meta: dict) -> str:
    """Resolve seed.cwd to an absolute path.

    Shared by zcode_runner.py and reference_runner.py (r3-mock-02 follow-up):
    a path already rooted at "/" is used as-is (matches most existing
    scenarios, e.g. command-commit-basic's "/tmp"). A scenario that ships its
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


def prepare_git_fixture(cwd: str) -> str:
    """Materialize a throwaway git repo seeded from a fixture directory.

    Some scenarios (e.g. ux-spinner-basic) exercise a tool that only runs
    inside a git repository -- zcode's dispatch gate refuses GitStatus/
    GitDiff/GitLog/GitCommit outside one (src/agent_tools.zig's
    `executeToolCall`: "Refuse git tools in a non-git workspace at
    dispatch"), and the real `claude` binary applies the same real-world
    constraint. Rather than committing a nested `.git/` into the checked-in
    fixture (git would track that as an embedded-repo gitlink, not plain
    files), copy the fixture into a fresh temp directory and `git init` +
    one commit there, per run.

    A scenario opts in with `"seed": {"git_repo": true, ...}` in meta.json.

    Returns the temp directory path. Not a context manager: callers already
    manage their own tempdir-scoped HOME with `with tempfile.
    TemporaryDirectory()`, and this needs to outlive that block in
    run_pty_scenario's flow (the fixture and the scratch HOME are cleaned up
    together) -- so the caller is responsible for `shutil.rmtree` when done.
    """
    workdir = tempfile.mkdtemp(prefix="zcode-pty-fixture-")
    dest = os.path.join(workdir, "repo")
    shutil.copytree(cwd, dest)
    git_env = os.environ.copy()
    git_env.update({
        "GIT_AUTHOR_NAME": "zcode-capture",
        "GIT_AUTHOR_EMAIL": "zcode-capture@example.invalid",
        "GIT_COMMITTER_NAME": "zcode-capture",
        "GIT_COMMITTER_EMAIL": "zcode-capture@example.invalid",
    })
    for git_cmd in (
        ["git", "init", "-q"],
        ["git", "add", "-A"],
        ["git", "commit", "-q", "-m", "seed fixture for capture"],
    ):
        subprocess.run(git_cmd, cwd=dest, env=git_env, check=True,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return dest


def build_interactive_command(mode: str, bin_path: str, meta: dict) -> list[str]:
    """Build the argv for a genuinely interactive (fullscreen REPL) session.

    Distinct from build_command below, which builds the headless `-p`
    invocation used by spawn_pty/write_frames (the single-shot path this
    module started with). run_interactive needs the CLI to actually start
    its REPL and idle at a prompt, so neither side may pass `-p`/`--print`.
    """
    if mode == "reference":
        return [bin_path]
    elif mode == "zcode":
        seed = meta.get("seed", {})
        return [bin_path, "--provider", seed.get("provider", "mock"),
                "--model", seed.get("model", "mock-agent")]
    else:
        raise SystemExit(f"unknown mode: {mode}")


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


def write_frames_multi(out_dir: Path, frames: list[tuple[int, bytes]]) -> int:
    """Write frames.bin as ADR 0010's length-prefixed sequence of terminal
    snapshots (one entry per captured chunk), instead of write_frames'
    single-frame shape. Used by run_interactive, whose scenario naturally
    produces many render boundaries (banner, spinner ticks, tool-approval
    prompt, final answer, exit) that are useful to diff independently.
    """
    frames_path = out_dir / "frames.bin"
    with open(frames_path, "wb") as f:
        for ts_ms, content in frames:
            f.write(struct.pack(">II", ts_ms % (2**32), len(content)))
            f.write(content)
    return len(frames)


# r3-mock-02: named keys understood by an `inputs[]` entry of type
# "keystroke" (ADR 0010's own example already uses `{"type": "keystroke",
# "value": "Enter"}`). Anything not in this table is written to the PTY
# verbatim as its UTF-8 encoding, so a single visible character (e.g. "y")
# needs no table entry at all.
KEYSTROKE_BYTES: dict[str, bytes] = {
    "Enter": b"\r",
    "Tab": b"\t",
    "Escape": b"\x1b",
    "Backspace": b"\x7f",
    "Ctrl+C": b"\x03",
    "Ctrl+D": b"\x04",
    "Up": b"\x1b[A",
    "Down": b"\x1b[B",
}


def run_interactive(
    cmd: list[str],
    cwd: str,
    env: dict,
    inputs: list[dict],
    timeout_s: float,
    cols: int = 110,
    rows: int = 36,
    settle_s: float = 0.5,
) -> list[tuple[int, bytes]]:
    """Drive an interactive (fullscreen-REPL-shaped) CLI over a real PTY.

    Unlike `spawn_pty` (headless: write stdin once, drain to EOF), this
    services a scenario's `inputs[]` list against the wall clock while
    continuously draining the PTY, so a scenario can wait for the app to
    settle (banner, spinner) before typing, exactly like the human this is
    standing in for. Each `os.read()` chunk is recorded as one frame with
    its millisecond timestamp -- an approximation of ADR 0010's "render
    boundary" (the app's full-screen synchronized-output writes usually
    surface as one read() each), good enough for a first interactive
    fixture; exact boundary detection is a follow-up.

    `inputs[]` entries:
      {"type": "command",   "value": "<text>"}   -- typed verbatim, no Enter
      {"type": "keystroke", "value": "<name>"}    -- KEYSTROKE_BYTES lookup,
                                                      or the literal bytes of
                                                      any other single value
      {"type": "wait_ms",   "value": <int>}       -- pause before the next
                                                      input, sends nothing

    Returns the captured (ts_ms, bytes) frame list. Always reaps the child
    (SIGKILL if it outlives `timeout_s`) before returning.
    """
    master_fd, slave_fd = pty.openpty()
    try:
        import fcntl
        import termios

        fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    except Exception:
        pass  # best-effort; an un-sized PTY still works, just at a default size

    pid = os.fork()
    if pid == 0:
        try:
            os.setsid()
            os.dup2(slave_fd, 0)
            os.dup2(slave_fd, 1)
            os.dup2(slave_fd, 2)
            os.close(master_fd)
            os.close(slave_fd)
            os.chdir(cwd)
            os.execvpe(cmd[0], cmd, env)
        except Exception:
            os._exit(127)
        os._exit(127)

    os.close(slave_fd)
    frames: list[tuple[int, bytes]] = []
    start = time.time()
    next_input_at = start + settle_s
    input_idx = 0

    def reap() -> None:
        try:
            os.kill(pid, 9)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except OSError:
            pass

    while time.time() - start < timeout_s:
        r, _, _ = select.select([master_fd], [], [], 0.2)
        if master_fd in r:
            try:
                chunk = os.read(master_fd, 65536)
            except OSError:
                break  # PTY closed -- the child exited (or is exiting)
            if not chunk:
                break
            frames.append((int(time.time() * 1000), chunk))

        now = time.time()
        if input_idx < len(inputs) and now >= next_input_at:
            item = inputs[input_idx]
            input_idx += 1
            itype = item.get("type")
            if itype == "wait_ms":
                next_input_at = now + (item.get("value", 0) / 1000.0)
                continue
            value = str(item.get("value", ""))
            data = KEYSTROKE_BYTES.get(value, value.encode("utf-8")) if itype == "keystroke" else value.encode("utf-8")
            try:
                os.write(master_fd, data)
            except OSError:
                pass
            next_input_at = now + 0.3  # let the app react before the next input

        try:
            wpid, _status = os.waitpid(pid, os.WNOHANG)
            if wpid == pid:
                break  # child already exited -- nothing more will arrive
        except ChildProcessError:
            break

    reap()
    try:
        os.close(master_fd)
    except OSError:
        pass
    return frames


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
