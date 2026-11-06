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


def prepare_v5_fixture(root, device, run):
    binaries = Path(os.environ.get("SYNCSTR_V5_TEST_BIN_DIR", root / ".build/v5-rust/debug"))
    generator = binaries / "examples/shared_audio_fixture"
    if not generator.is_file() or not os.access(generator, os.X_OK):
        raise RuntimeError("Required v5 fixture generator is missing; build shared_audio_fixture first")
    app = root / ".build/SimulatorDerivedData/Build/Products/Debug-iphonesimulator/Syncstr.app"
    with (app / "Info.plist").open("rb") as info:
        bundle_id = plistlib.load(info)["CFBundleIdentifier"]
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


def main():
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
        timeout = 180 if name in ("bootstatus", "restart-ready") else 1200
        started = time.monotonic()
        try:
            with (output / (name + ".log")).open("w") as log:
                subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT,
                               check=True, env=environment, timeout=timeout)
        finally:
            elapsed = time.monotonic() - started
            command_timings[name] = {"elapsedSeconds": elapsed, "timeoutSeconds": timeout,
                                     "remainingSeconds": timeout - elapsed}
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
    try:
        (output / "environment.json").write_text(json.dumps({
            "runtime": runtime, "device": device, "deviceType": device_type,
            "language": "ja", "locale": "ja_JP", "orientation": "portrait",
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
        for scheme, name in [("Syncstr", "unit"), ("Syncstr", "responsiveness"), ("SyncstrUITests", "ui")]:
            environment = None
            if name == "ui" and (not args.only_testing or any("SharedAudioFlowTests" in item for item in args.only_testing)):
                fixture = prepare_v5_fixture(root, device, run)
                environment = dict(os.environ, TEST_RUNNER_SYNCSTR_V5_FIXTURE_ROOT=fixture)
            command = [
                "xcodebuild", "-project", "apps/ios/Syncstr.xcodeproj", "-scheme", scheme,
                "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
                "-destination", "platform=iOS Simulator,id=" + device,
                "-derivedDataPath", str(root / ".build" / "SimulatorDerivedData"),
                "-resultBundlePath", str(output / (name + ".xcresult")),
                "-parallel-testing-enabled", "NO", "-testLanguage", "ja", "-testRegion", "JP",
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
    except subprocess.CalledProcessError as error:
        status = error.returncode
        raise
    finally:
        cleanup = []
        for action in ("shutdown", "delete"):
            result = subprocess.run(["xcrun", "simctl", action, device], capture_output=True, text=True)
            cleanup.append({"action": action, "status": result.returncode, "stderr": result.stderr})
        status = status or cleanup[-1]["status"]
        (output / "result.json").write_text(json.dumps({"status": status, "cleanup": cleanup}, indent=2) + "\n")
        print(f"Verification {'passed' if status == 0 else 'failed'}: {output}", flush=True)
    return status


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as error:
        print(f"Command failed ({error.returncode}): {error.cmd}", file=sys.stderr)
        sys.exit(error.returncode)
