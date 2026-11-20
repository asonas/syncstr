#!/usr/bin/env python3
"""Run unit and UI tests on a disposable iOS 27.0 Simulator."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time


INFRASTRUCTURE_EXIT = 78
PREPARATION_STEPS = {"boot", "bootstatus", "migration-shutdown", "restart", "restart-ready",
                     "unit-ready", "responsiveness-ready", "ui-ready"}


class SimulatorInfrastructureError(RuntimeError):
    def __init__(self, stage, cause):
        super().__init__(f"Simulator preparation failed at {stage}: {cause}")
        self.stage = stage
        self.cause = cause


def command_timeout(name):
    if name == "bootstatus" or name.endswith("-ready"):
        return 180
    return 1800 if name in ("ui", "ui-retry") else 1200


def test_attempts(tree):
    def repetitions(node):
        return (1 if node.get("nodeType") == "Repetition" else
                sum(repetitions(child) for child in node.get("children", [])))

    def visit(node):
        if isinstance(node, list):
            return {test: attempts for child in node for test, attempts in visit(child).items()}
        if isinstance(node, dict):
            if node.get("nodeType") == "Test Case":
                return {node["nodeIdentifier"]: (node.get("result"), max(1, repetitions(node)))}
            return {test: attempts for value in node.values() if isinstance(value, (dict, list))
                    for test, attempts in visit(value).items()}
        return {}

    return visit(tree)


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

    def run(command, name):
        timeout = command_timeout(name)
        started = time.monotonic()
        outcome = "passed"
        try:
            with (output / (name + ".log")).open("w") as log:
                subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT,
                               check=True, timeout=timeout)
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
            outcome = "timed_out" if isinstance(error, subprocess.TimeoutExpired) else "failed"
            if name in PREPARATION_STEPS:
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
            bundle = output / (name + ".xcresult")
            try:
                run(command, name)
            except subprocess.CalledProcessError:
                # Xcode can restart a crashed runner at the next test, skipping its retry.
                if "Restarting after unexpected exit, crash, or test timeout" not in (output / (name + ".log")).read_text():
                    raise
                run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path",
                     str(bundle)], name + "-tests")
                failures = {test: attempts for test, (result, attempts) in test_attempts(
                    json.loads((output / (name + "-tests.log")).read_text())).items() if result == "Failed"}
                tests = sorted(test for test, attempts in failures.items() if attempts < 2)
                if not tests:
                    raise
                (output / (name + "-retry.json")).write_text(json.dumps({"tests": tests}) + "\n")
                retry = [arg for arg in command if arg != "-retry-tests-on-failure"
                         and not arg.startswith("-only-testing:")]
                iterations = retry.index("-test-iterations")
                del retry[iterations:iterations + 2]
                bundle = output / (name + "-retry.xcresult")
                retry[retry.index("-resultBundlePath") + 1] = str(bundle)
                target = "SyncstrUITests" if name == "ui" else "SyncstrTests"
                retry += ["-only-testing:" + (test if test.startswith(target + "/") else target + "/" + test)
                          for test in tests]
                run(retry, name + "-retry")
                run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path",
                     str(bundle)], name + "-retry-tests")
                retried = test_attempts(json.loads((output / (name + "-retry-tests.log")).read_text()))
                if any(retried.get(test, (None, 0))[0] != "Passed" for test in tests):
                    raise RuntimeError("Every fallback test must run and pass")
                if set(failures) - set(tests):
                    raise
            run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path",
                 str(bundle)], name + "-summary")
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
