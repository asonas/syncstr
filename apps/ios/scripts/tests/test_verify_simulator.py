import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


class SimulatorRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.script = self.root / "apps/ios/scripts/verify_simulator.py"
        self.script.parent.mkdir(parents=True)
        shutil.copyfile(Path(__file__).resolve().parents[1] / "verify_simulator.py", self.script)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "calls.jsonl"
        app = self.root / ".build/SimulatorDerivedData/Build/Products/Debug-iphonesimulator/Syncstr.app"
        app.mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "example.fixture"}))
        fake = "#!" + sys.executable + "\n" + '''
import json, os, pathlib, sys
command = [pathlib.Path(sys.argv[0]).name] + sys.argv[1:]
with open(os.environ["CALLS"], "a") as log:
    log.write(json.dumps(command) + "\\n")
if command[1:4] == ["simctl", "list", "runtimes"]:
    print(json.dumps({"runtimes": [
        {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-0", "version": "26.0", "isAvailable": True},
        {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0", "isAvailable": True},
        {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1", "version": "27.1", "isAvailable": True}
    ]}))
if command[1:3] == ["simctl", "create"]:
    print("owned-simulator")
if command[1:3] == ["simctl", "get_app_container"]:
    print(os.environ["CONTAINER"])
if command[0] == "shared_audio_fixture":
    root = pathlib.Path(command[1])
    root.mkdir()
    for name in ("snapshot.json", "reader-enrollment.json", "tone.wav", "private.key", "token"):
        (root / name).write_text("synthetic")
if command[0] == "xcodebuild" and "SyncstrUITests" in command and "test" in command:
    print(os.environ.get("TEST_RUNNER_SYNCSTR_V5_FIXTURE_ROOT", ""))
if command[1:5] == ["xcresulttool", "get", "test-results", "summary"]:
    print(json.dumps({"passedTests": 0 if os.environ.get("FAIL") == "empty" else 1, "failedTests": 0}))
if os.environ.get("FAIL") == "boot" and command[1:3] == ["simctl", "boot"]:
    sys.exit(42)
if os.environ.get("FAIL") == "test" and command[0] == "xcodebuild" and "test" in command:
    print("test failed")
    sys.exit(65)
if os.environ.get("FAIL") == "delete" and command[1:3] == ["simctl", "delete"]:
    sys.exit(43)
'''
        for name in ("xcrun", "xcodegen", "xcodebuild", "shared_audio_fixture"):
            path = self.bin / name
            path.write_text(fake)
            path.chmod(0o755)

    def run_script(self, failure="", device="iphone", selection="SyncstrUITests/LibraryExperienceTests"):
        binaries = self.root / "v5-bin"
        (binaries / "examples").mkdir(parents=True)
        if failure != "missing-v5":
            shutil.copyfile(self.bin / "shared_audio_fixture", binaries / "examples/shared_audio_fixture")
            (binaries / "examples/shared_audio_fixture").chmod(0o755)
        environment = dict(os.environ, PATH=str(self.bin), CALLS=str(self.calls), FAIL=failure,
                           CONTAINER=str(self.root / "app-data"), SYNCSTR_V5_TEST_BIN_DIR=str(binaries))
        result = subprocess.run(
            [sys.executable, str(self.script), "--device", device,
             "--only-testing", selection],
            env=environment, capture_output=True, text=True)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        output = next((self.root / ".build/verification").iterdir())
        return result, calls, output

    def test_v5_preparation_copies_only_public_fixture_inputs(self):
        result, calls, output = self.run_script(selection="SyncstrUITests/SharedAudioFlowTests")
        self.assertEqual(result.returncode, 0, result.stderr)
        destination = self.root / "app-data/Documents/v5-fixture"
        self.assertEqual(sorted(path.name for path in destination.iterdir()),
                         ["reader-enrollment.json", "snapshot.json", "tone.wav"])
        generated = next(call for call in calls if call[0] == "shared_audio_fixture")
        self.assertFalse(Path(generated[1]).exists())
        self.assertTrue(any(call[1:3] == ["simctl", "install"] for call in calls))
        self.assertEqual((output / "ui.log").read_text().strip(), "v5-fixture")

    def test_missing_v5_generator_fails_before_ui_execution(self):
        result, calls, _output = self.run_script("missing-v5", selection="SyncstrUITests/SharedAudioFlowTests")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Required v5 fixture generator is missing", result.stderr)
        self.assertFalse(any("SyncstrUITests" in call for call in calls if call[0] == "xcodebuild"))
        self.assertEqual(calls[-1], ["xcrun", "simctl", "delete", "owned-simulator"])

    def test_success_records_results_and_deletes_only_the_created_device(self):
        result, calls, output = self.run_script(device="ipad")
        self.assertEqual(result.returncode, 0, result.stderr)
        create = next(call for call in calls if call[1:3] == ["simctl", "create"])
        self.assertEqual(create[-1], "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        self.assertEqual(create[-2], "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB")
        builds = [call for call in calls if call[0] == "xcodebuild" and "test" in call]
        self.assertEqual(len(builds), 3)
        for build in builds:
            self.assertIn("platform=iOS Simulator,id=owned-simulator", build)
            self.assertEqual(build[build.index("-testLanguage") + 1], "ja")
            self.assertEqual(build[build.index("-testRegion") + 1], "JP")
            self.assertEqual(build[build.index("-parallel-testing-enabled") + 1], "NO")
        self.assertNotIn("-only-testing:SyncstrUITests/LibraryExperienceTests", builds[0])
        self.assertIn("-only-testing:SyncstrUITests/LibraryExperienceTests", builds[2])
        measurement = "SyncstrTests/LibraryPresentationTests/testSelectionAndPlaybackUpdatesBrowseRetainedCatalogWithoutBlocking()"
        self.assertIn("-skip-testing:" + measurement, builds[0])
        self.assertIn("-only-testing:" + measurement, builds[1])
        self.assertEqual(calls[-2:], [["xcrun", "simctl", action, "owned-simulator"] for action in ("shutdown", "delete")])
        self.assertEqual(json.loads((output / "result.json").read_text())["status"], 0)
        self.assertTrue((output / "unit.log").exists())
        self.assertTrue((output / "ui.log").exists())
        timings = json.loads((output / "command-timings.json").read_text())
        self.assertEqual(timings["ui"]["timeoutSeconds"], 1200)
        self.assertEqual(timings["bootstatus"]["timeoutSeconds"], 180)
        self.assertGreaterEqual(timings["ui"]["elapsedSeconds"], 0)
        self.assertAlmostEqual(timings["ui"]["remainingSeconds"],
                               1200 - timings["ui"]["elapsedSeconds"])

    def test_failed_test_preserves_failure_and_cleans_up(self):
        result, calls, output = self.run_script("test")
        self.assertEqual(result.returncode, 65)
        self.assertEqual(calls[-1], ["xcrun", "simctl", "delete", "owned-simulator"])
        self.assertEqual((output / "unit.log").read_text().strip(), "test failed")
        self.assertEqual(json.loads((output / "result.json").read_text())["status"], 65)
        self.assertIn("unit", json.loads((output / "command-timings.json").read_text()))

    def test_timeout_keeps_elapsed_time_and_still_cleans_up(self):
        spec = importlib.util.spec_from_file_location("verification", self.script)
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        runtime = {"runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                                  "isAvailable": True}]}
        calls = []

        def run(command, **options):
            calls.append(command)
            if command[1:3] == ["simctl", "boot"]:
                self.assertEqual(options["timeout"], 1200)
                raise subprocess.TimeoutExpired(command, options["timeout"])
            return subprocess.CompletedProcess(command, 0, stdout="", stderr="")

        with patch.object(sys, "argv", [str(self.script)]), \
                patch.object(runner.subprocess, "check_output", side_effect=[
                    json.dumps(runtime).encode(), "owned-simulator\n"]), \
                patch.object(runner.subprocess, "run", side_effect=run), \
                patch.object(runner.time, "monotonic", side_effect=[100.0, 1300.0]):
            with self.assertRaises(subprocess.TimeoutExpired):
                runner.main()

        output = next((self.root / ".build/verification").iterdir())
        timings = json.loads((output / "command-timings.json").read_text())
        self.assertEqual(timings["boot"], {
            "elapsedSeconds": 1200.0, "timeoutSeconds": 1200, "remainingSeconds": 0.0})
        self.assertEqual(json.loads((output / "result.json").read_text())["status"], 1)
        self.assertEqual(calls[-2:], [["xcrun", "simctl", action, "owned-simulator"]
                                     for action in ("shutdown", "delete")])

    def test_failed_boot_also_cleans_up_without_running_tests(self):
        result, calls, output = self.run_script("boot")
        self.assertEqual(result.returncode, 42)
        self.assertEqual(calls[-1], ["xcrun", "simctl", "delete", "owned-simulator"])
        self.assertFalse(any(call[0] == "xcodebuild" for call in calls))
        self.assertTrue((output / "boot.log").exists())

    def test_failed_cleanup_is_not_reported_as_success(self):
        result, calls, output = self.run_script("delete")
        self.assertEqual(result.returncode, 43)
        self.assertEqual(json.loads((output / "result.json").read_text())["status"], 43)
        self.assertIn("Verification failed", result.stdout)

    def test_empty_test_selection_does_not_pass(self):
        result, calls, output = self.run_script("empty")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must contain passing tests", result.stderr)
        self.assertEqual(calls[-1], ["xcrun", "simctl", "delete", "owned-simulator"])


if __name__ == "__main__":
    unittest.main()
