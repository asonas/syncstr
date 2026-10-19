#!/usr/bin/env python3
"""Run unit and UI tests on a disposable iOS 27.0 Simulator."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile


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

    def run(command, name):
        with (output / (name + ".log")).open("w") as log:
            subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=180 if name in ("bootstatus", "restart-ready") else 1200)

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
            run(command, name)
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
