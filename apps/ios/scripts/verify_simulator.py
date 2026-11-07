#!/usr/bin/env python3
"""Run unit and UI tests on a disposable iOS 27.0 Simulator."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time


INFRASTRUCTURE_EXIT = 78
PREPARATION_STEPS = {"boot", "bootstatus", "migration-shutdown", "restart", "restart-ready",
                     "v5-ready", "unit-ready", "responsiveness-ready", "ui-ready"}


class SimulatorInfrastructureError(RuntimeError):
    def __init__(self, stage, cause):
        super().__init__(f"Simulator preparation failed at {stage}: {cause}")
        self.stage = stage
        self.cause = cause


def prepare_v5_fixture(root, device, run):
    binaries = Path(os.environ.get("SYNCSTR_V5_TEST_BIN_DIR", root / ".build/v5-rust/debug"))
    generator = binaries / "examples/shared_audio_fixture"
    if not generator.is_file() or not os.access(generator, os.X_OK):
        raise RuntimeError("Required v5 fixture generator is missing; build shared_audio_fixture first")
    app = root / ".build/SimulatorDerivedData/Build/Products/Debug-iphonesimulator/Syncstr.app"
    with (app / "Info.plist").open("rb") as info:
        bundle_id = plistlib.load(info)["CFBundleIdentifier"]
    # Xcode can leave the requested device shut down after a preceding test phase.
    run(["xcrun", "simctl", "bootstatus", device, "-b"], "v5-ready")
    run(["xcrun", "simctl", "install", device, str(app)], "v5-install")
    container = Path(subprocess.check_output(
        ["xcrun", "simctl", "get_app_container", device, bundle_id, "data"], text=True).strip())
    destination = container / "Documents/v5-fixture"
    destination.mkdir(parents=True)
    # Keep generated signing keys/tokens out of the app and uploaded test artifacts.
    with tempfile.TemporaryDirectory(prefix="syncstr-v5-private-") as temporary:
        source = Path(temporary) / "fixture"
        run([str(generator), str(source)], "v5-generate")
        for name in ("snapshot.json", "reader-enrollment.json", "tone.wav"):
            shutil.copyfile(source / name, destination / name)
    # Xcode may relocate the data container when it installs the UI-test build.
    return "v5-fixture"


def main(attempt=1):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", choices=("iphone", "ipad"), default="iphone")
    parser.add_argument("--only-testing", action="append", default=[], help="UI test filter")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    results = root / ".build" / "verification"
    results.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix=args.device + "-", dir=results))
    print(f"Verification results: {output}", flush=True)
    command_timings = {}

    def run(command, name, environment=None):
        timeout = 180 if name == "bootstatus" or name.endswith("-ready") else 1200
        started = time.monotonic()
        outcome = "passed"
        try:
            with (output / (name + ".log")).open("w") as log:
                subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT,
                               check=True, env=environment, timeout=timeout)
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
            outcome = "timed_out" if isinstance(error, subprocess.TimeoutExpired) else "failed"
            if name in PREPARATION_STEPS or (name == "v5-install" and
                    (isinstance(error, subprocess.TimeoutExpired) or error.returncode == 149)):
                raise SimulatorInfrastructureError(name, error) from error
            raise
        finally:
            elapsed = time.monotonic() - started
            command_timings[name] = {"elapsedSeconds": elapsed, "timeoutSeconds": timeout,
                                     "remainingSeconds": timeout - elapsed, "outcome": outcome}
            (output / "command-timings.json").write_text(json.dumps(command_timings, indent=2) + "\n")
            print(f"{name}: {elapsed:.3f}s of {timeout}s ({timeout - elapsed:.3f}s remaining)", flush=True)

    runtime_data = subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "--json"])
    runtimes = [runtime for runtime in json.loads(runtime_data)["runtimes"]
                if runtime.get("isAvailable") and runtime["identifier"] == "com.apple.CoreSimulator.SimRuntime.iOS-27-0"]
    if not runtimes:
        parser.error("Install the iOS 27.0 Simulator runtime in Xcode Settings > Components.")
    runtime = runtimes[0]
    device_type = {"iphone": "iPhone-18-Pro", "ipad": "iPad-Pro-13-inch-M5-12GB"}[args.device]
    device = subprocess.check_output([
        "xcrun", "simctl", "create", "Syncstr Verification", "com.apple.CoreSimulator.SimDeviceType." + device_type,
        runtime["identifier"],
    ], text=True).strip()
    status = 1
    failure = None
    try:
        (output / "environment.json").write_text(json.dumps({
            "runtime": runtime, "device": device, "deviceType": device_type,
            "language": "ja", "locale": "ja_JP", "orientation": "portrait", "attempt": attempt,
        }, indent=2) + "\n")
        run(["xcrun", "simctl", "boot", device], "boot")
        run(["xcrun", "simctl", "bootstatus", device, "-b"], "bootstatus")
        # Fresh iOS 27 devices can stall in the launch bridge after migration.
        run(["xcrun", "simctl", "shutdown", device], "migration-shutdown")
        run(["xcrun", "simctl", "boot", device], "restart")
        run(["xcrun", "simctl", "bootstatus", device, "-b"], "restart-ready")
        run(["xcodegen", "generate", "--spec", "apps/ios/project.yml"], "generate")
        run(["xcodebuild", "-resolvePackageDependencies", "-project", "apps/ios/Syncstr.xcodeproj",
             "-scheme", "Syncstr", "-derivedDataPath", str(root / ".build" / "SimulatorDerivedData"),
             "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile"], "resolve")
        responsiveness = "SyncstrTests/LibraryPresentationTests/testSelectionAndPlaybackUpdatesBrowseRetainedCatalogWithoutBlocking()"
        phases = [("Syncstr", "unit"), ("Syncstr", "responsiveness")] if args.device == "iphone" else []
        for scheme, name in phases + [("SyncstrUITests", "ui")]:
            environment = None
            if name == "ui" and (not args.only_testing or any("SharedAudioFlowTests" in item for item in args.only_testing)):
                fixture = prepare_v5_fixture(root, device, run)
                environment = dict(os.environ, TEST_RUNNER_SYNCSTR_V5_FIXTURE_ROOT=fixture)
            run(["xcrun", "simctl", "bootstatus", device, "-b"], name + "-ready")
            command = [
                "xcodebuild", "-project", "apps/ios/Syncstr.xcodeproj", "-scheme", scheme,
                "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
                "-destination", "platform=iOS Simulator,id=" + device,
                "-derivedDataPath", str(root / ".build" / "SimulatorDerivedData"),
                "-resultBundlePath", str(output / (name + ".xcresult")),
                "-parallel-testing-enabled", "NO", "-testLanguage", "ja", "-testRegion", "JP",
                "-retry-tests-on-failure", "-test-iterations", "2",
                "CODE_SIGNING_ALLOWED=NO", "test",
            ]
            if name == "ui":
                command += ["-only-testing:" + target for target in args.only_testing]
            elif name == "responsiveness":
                command += ["-only-testing:" + responsiveness]
            else:
                command += ["-skip-testing:" + responsiveness]
            run(command, name, environment)
            run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path",
                 str(output / (name + ".xcresult"))], name + "-summary")
            summary = json.loads((output / (name + "-summary.log")).read_text())
            if summary["passedTests"] == 0 or summary["failedTests"] != 0:
                raise RuntimeError(f"{name} must contain passing tests and no failures")
        status = 0
    except SimulatorInfrastructureError as error:
        status = INFRASTRUCTURE_EXIT
        failure = {"classification": "simulator-infrastructure", "stage": error.stage,
                   "kind": "timeout" if isinstance(error.cause, subprocess.TimeoutExpired) else "exit",
                   "returnCode": getattr(error.cause, "returncode", None)}
        raise
    except subprocess.CalledProcessError as error:
        status = error.returncode
        raise
    finally:
        cleanup = []
        for action in ("shutdown", "delete"):
            try:
                result = subprocess.run(["xcrun", "simctl", action, device], capture_output=True,
                                        text=True, timeout=60)
                cleanup.append({"action": action, "status": result.returncode, "stderr": result.stderr})
            except subprocess.TimeoutExpired:
                cleanup.append({"action": action, "status": 124, "stderr": "Cleanup exceeded 60 seconds"})
        status = status or cleanup[-1]["status"]
        (output / "result.json").write_text(json.dumps({"status": status, "cleanup": cleanup,
            "attempt": attempt, "failure": failure, "retryScheduled": failure is not None and attempt == 1},
            indent=2) + "\n")
        print(f"Verification {'passed' if status == 0 else 'failed'}: {output}", flush=True)
    return status


def verify():
    for attempt in (1, 2):
        try:
            return main(attempt)
        except SimulatorInfrastructureError as error:
            level = "warning" if attempt == 1 else "error"
            print(f"::{level} title=Simulator infrastructure::{error} (attempt {attempt}/2)", flush=True)
            if attempt == 1:
                print("Retrying verification once with a fresh disposable Simulator.", flush=True)
    return INFRASTRUCTURE_EXIT


if __name__ == "__main__":
    try:
        sys.exit(verify())
    except subprocess.CalledProcessError as error:
        print(f"Command failed ({error.returncode}): {error.cmd}", file=sys.stderr)
        sys.exit(error.returncode)
