import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


RUN_SCRIPT = Path(__file__).resolve().parents[1] / "run.sh"
COMMAND_FIXTURE = r'''
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["RUN_FIXTURE"])
command = Path(sys.argv[0]).name
state_file = root / "processes.json"
processes = json.loads(state_file.read_text())
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps([command, *sys.argv[1:]]) + "\n")
if command == "ps":
    if os.environ.get("PS_FAIL"):
        sys.exit("Cannot list processes")
    for uid, pid, path in processes:
        print(f"  {uid} {pid} {path}")
elif command == "kill":
    if sys.argv[1] != "-TERM":
        sys.exit("Only TERM is allowed")
    if not os.environ.get("KEEP_RUNNING"):
        processes = [p for p in processes if p[1] != int(sys.argv[2])]
elif command == "open":
    if sys.argv[1] != "-n":
        sys.exit("Expected explicit app launch")
    mode = os.environ.get("LAUNCH_MODE", "normal")
    path = sys.argv[2] + "/Contents/MacOS/Syncstr"
    if mode == "wrong":
        path = "/old/Syncstr.app/Contents/MacOS/Syncstr"
    if mode != "missing":
        processes.append([os.getuid(), 9001, path])
    if mode == "duplicate":
        processes.append([os.getuid(), 9002, path])
state_file.write_text(json.dumps(processes))
'''


class RunScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="syncstr-run-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.app = self.root / "build with spaces" / "Syncstr.app"
        self.executable = self.app / "Contents/MacOS/Syncstr"
        self.executable.parent.mkdir(parents=True)
        self.executable.write_text("#!/bin/sh\nexit 0\n")
        self.executable.chmod(0o700)
        self.commands = self.root / "commands"
        self.commands.mkdir()
        fixture = self.commands / "fixture"
        fixture.write_text(f"#!{sys.executable}\n" + COMMAND_FIXTURE)
        fixture.chmod(0o700)
        for name in ["ps", "kill", "open", "sleep"]:
            (self.commands / name).symlink_to(fixture)
        self.uid = os.getuid()
        self.lock = self.root / f"syncstr-run-{self.uid}.lock"
        self.set_processes([])

    def set_processes(self, processes):
        (self.root / "processes.json").write_text(json.dumps(processes))

    def calls(self):
        log = self.root / "calls.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def run_app(self, app=None, **overrides):
        env = dict(os.environ, PATH=f"{self.commands}:/usr/bin:/bin", TMPDIR=str(self.root),
                   RUN_FIXTURE=str(self.root), **overrides)
        return subprocess.run(["/bin/sh", str(RUN_SCRIPT), str(app or self.app)], env=env,
                              capture_output=True, text=True, timeout=15)

    def test_replaces_old_builds_including_deleted_worktrees(self):
        other_processes = [
            [self.uid, 102, "/other/Player.app/Contents/MacOS/Player"],
            [self.uid + 1, 103, "/other/Syncstr.app/Contents/MacOS/Syncstr"],
        ]
        self.set_processes([
            [self.uid, 100, "/deleted/worktree/Syncstr.app/Contents/MacOS/Syncstr"],
            [self.uid, 101, "/old build/Syncstr.app/Contents/MacOS/Syncstr"],
            *other_processes,
        ])
        result = self.run_app()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("/deleted/worktree/Syncstr.app/Contents/MacOS/Syncstr", result.stdout)
        self.assertIn(str(self.executable), result.stdout)
        self.assertEqual([c for c in self.calls() if c[0] in ["kill", "open"]], [
            ["kill", "-TERM", "100"], ["kill", "-TERM", "101"], ["open", "-n", str(self.app)],
        ])
        self.assertEqual(json.loads((self.root / "processes.json").read_text()),
                         [*other_processes, [self.uid, 9001, str(self.executable)]])
        self.assertFalse(self.lock.exists())

    def test_repeated_launch_keeps_one_target_process(self):
        for _ in range(2):
            result = self.run_app()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(self.lock.exists())
        self.assertEqual(json.loads((self.root / "processes.json").read_text()),
                         [[self.uid, 9001, str(self.executable)]])

    def test_does_not_launch_if_old_process_will_not_exit(self):
        self.set_processes([[self.uid, 100, "/old/Syncstr.app/Contents/MacOS/Syncstr"]])
        result = self.run_app(KEEP_RUNNING="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not exit", result.stderr)
        self.assertFalse(any(c[0] == "open" for c in self.calls()))
        self.assertEqual([c for c in self.calls() if c[0] == "kill"], [["kill", "-TERM", "100"]])
        self.assertEqual(len([c for c in self.calls() if c[0] == "sleep"]), 10)
        self.assertFalse(self.lock.exists())

    def test_rejects_missing_wrong_or_duplicate_launched_processes(self):
        for mode, error in [("missing", "did not start"), ("wrong", "Unexpected"),
                            ("duplicate", "Unexpected")]:
            with self.subTest(mode=mode):
                self.set_processes([])
                result = self.run_app(LAUNCH_MODE=mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stderr)
                self.assertFalse(self.lock.exists())

    def test_process_listing_failure_does_not_launch(self):
        result = self.run_app(PS_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot list processes", result.stderr)
        self.assertFalse(any(c[0] in ["kill", "open"] for c in self.calls()))
        self.assertFalse(self.lock.exists())

    def test_missing_build_and_existing_lock_leave_processes_alone(self):
        result = self.run_app(self.root / "missing/Syncstr.app")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Build Syncstr first", result.stderr)
        self.lock.mkdir()
        result = self.run_app()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Another launch", result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertTrue(self.lock.exists())


if __name__ == "__main__":
    unittest.main()
