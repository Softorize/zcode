#!/usr/bin/env python3
"""Proof for r3-mock-02's compare.py frame-status disambiguation.

Before this fix, compare.py's `diff_frames` collapsed "neither side has
been captured" and "only zcode has been captured" (the normal state for
every scenario in this repo today -- reference/ is gitignored as a
regenerable, machine-specific artifact, see scenarios/.gitignore) into one
ambiguous `kind: "not_captured"`, indistinguishable from a genuine capture
failure. This monkeypatches compare.SCENARIOS_ROOT to a temp directory and
asserts each of the four distinguishable states `diff_frames` can report,
proving the fix by calling the real function rather than re-describing it.

Also proves pty_capture.build_interactive_command builds a genuinely
interactive argv (no -p/--print/exec) for both reference and zcode modes,
and that prepare_git_fixture leaves a real git repo with a clean working
tree (the state src/agent_tools.zig's `is_git_repo` dispatch gate checks
for) without touching the source fixture directory it copies from.

Does NOT spawn `claude` or `zcode`, and does NOT depend on either being
installed (prepare_git_fixture only needs `git`, which every dev/CI
environment already has for this repo itself). Pure logic + filesystem
proof, run directly: `python3 tools/capture/frame_capture_status_test.py`.
"""

from __future__ import annotations

import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import compare  # noqa: E402
import pty_capture  # noqa: E402


def write_frames_bin(path: Path, content: bytes = b"frame") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        f.write(struct.pack(">II", 0, len(content)))
        f.write(content)


def check(condition: bool, msg: str) -> None:
    if not condition:
        raise AssertionError(msg)


def test_diff_frames_four_states(tmp_root: Path) -> None:
    scenario = "fake-scenario"
    scenario_dir = tmp_root / scenario

    original_root = compare.SCENARIOS_ROOT
    compare.SCENARIOS_ROOT = tmp_root
    try:
        # Neither side captured.
        result = compare.diff_frames(scenario)
        check(result["kind"] == "not_captured", f"expected not_captured, got {result['kind']}")
        check(result["reference_frames_present"] is False, "ref should be absent")
        check(result["zcode_frames_present"] is False, "zcode should be absent")

        # zcode only -- the common state today for every real scenario.
        write_frames_bin(scenario_dir / "zcode" / "frames.bin", b"zcode frame")
        result = compare.diff_frames(scenario)
        check(result["kind"] == "zcode_only_capture", f"expected zcode_only_capture, got {result['kind']}")
        check(result["zcode_frames_present"] is True, "zcode should be present")
        check(result["reference_frames_present"] is False, "ref should still be absent")

        # Swap: reference only.
        shutil.rmtree(scenario_dir / "zcode")
        write_frames_bin(scenario_dir / "reference" / "frames.bin", b"ref frame")
        result = compare.diff_frames(scenario)
        check(result["kind"] == "reference_only_capture", f"expected reference_only_capture, got {result['kind']}")
        check(result["reference_frames_present"] is True, "ref should be present")
        check(result["zcode_frames_present"] is False, "zcode should be absent")

        # Both present -> the original diffed path still works.
        write_frames_bin(scenario_dir / "zcode" / "frames.bin", b"ref frame")  # identical text
        result = compare.diff_frames(scenario)
        check(result["kind"] == "diffed", f"expected diffed, got {result['kind']}")
        check(result["reference_frames_present"] is True, "ref should be present")
        check(result["zcode_frames_present"] is True, "zcode should be present")
    finally:
        compare.SCENARIOS_ROOT = original_root

    print("OK: diff_frames reports all four distinguishable states")


def test_build_interactive_command_has_no_headless_flags() -> None:
    meta = {"seed": {"provider": "mock", "model": "mock-agent"}}

    ref_cmd = pty_capture.build_interactive_command("reference", "/bin/claude", meta)
    check(ref_cmd == ["/bin/claude"], f"reference interactive command should be bare, got {ref_cmd}")

    zcode_cmd = pty_capture.build_interactive_command("zcode", "/bin/zcode", meta)
    check("-p" not in zcode_cmd and "exec" not in zcode_cmd,
          f"zcode interactive command must not use the headless path, got {zcode_cmd}")
    check("--provider" in zcode_cmd and "mock" in zcode_cmd, f"expected provider flag, got {zcode_cmd}")

    print("OK: build_interactive_command never emits a headless flag")


def test_prepare_git_fixture_is_isolated_and_clean(tmp_root: Path) -> None:
    source = tmp_root / "fixture-source"
    source.mkdir()
    (source / "README.md").write_text("fixture repo for a test\n", encoding="utf-8")

    workdir = pty_capture.prepare_git_fixture(str(source))
    try:
        # The source fixture is untouched -- no .git/ leaked into checked-in state.
        check(not (source / ".git").exists(), "source fixture must stay a plain directory")
        check(sorted(p.name for p in source.iterdir()) == ["README.md"],
              "source fixture must contain only what it started with")

        workdir_path = Path(workdir)
        check((workdir_path / ".git").is_dir(), "staged copy must be a real git repo")
        check((workdir_path / "README.md").read_text(encoding="utf-8") == "fixture repo for a test\n",
              "staged copy must carry over the fixture's own files")

        status = subprocess.run(
            ["git", "status", "--porcelain"], cwd=workdir, capture_output=True, text=True, check=True,
        )
        check(status.stdout.strip() == "", f"staged repo must have a clean tree, got {status.stdout!r}")

        log = subprocess.run(
            ["git", "log", "--oneline"], cwd=workdir, capture_output=True, text=True, check=True,
        )
        check(log.stdout.strip() != "", "staged repo must have at least one commit")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    print("OK: prepare_git_fixture stages an isolated, clean, committed repo")


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        test_diff_frames_four_states(Path(tmp))
    test_build_interactive_command_has_no_headless_flags()
    with tempfile.TemporaryDirectory() as tmp:
        test_prepare_git_fixture_is_isolated_and_clean(Path(tmp))
    return 0


if __name__ == "__main__":
    sys.exit(main())
