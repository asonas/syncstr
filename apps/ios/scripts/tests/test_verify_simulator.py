import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


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
        for name in ("xcrun", "xcodegen", "xcodebuild"):
            path = self.bin / name
            path.write_text(fake)
            path.chmod(0o755)

    def run_script(self, failure="", device="iphone"):
        environment = dict(os.environ, PATH=str(self.bin), CALLS=str(self.calls), FAIL=failure)
        result = subprocess.run(
            [sys.executable, str(self.script), "--device", device,
             "--only-testing", "SyncstrUITests/LibraryExperienceTests"],
            env=environment, capture_output=True, text=True)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        output = next((self.root / ".build/verification").iterdir())
        return result, calls, output

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

    def test_failed_test_preserves_failure_and_cleans_up(self):
        result, calls, output = self.run_script("test")
        self.assertEqual(result.returncode, 65)
        self.assertEqual(calls[-1], ["xcrun", "simctl", "delete", "owned-simulator"])
        self.assertEqual((output / "unit.log").read_text().strip(), "test failed")
        self.assertEqual(json.loads((output / "result.json").read_text())["status"], 65)

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
