"""Collect dependency notices from the exact Cargo.lock used to build the binary."""

import json
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    destination = Path(sys.argv[1])
    destination.mkdir(parents=True, exist_ok=True)
    compiler = subprocess.check_output(["rustc", "-vV"], text=True)
    platform = next(line.removeprefix("host: ") for line in compiler.splitlines() if line.startswith("host: "))
    metadata = json.loads(subprocess.check_output(
        ["cargo", "metadata", "--locked", "--format-version", "1", "--filter-platform", platform], text=True
    ))
    tree = subprocess.check_output(
        ["cargo", "tree", "--locked", "--target", platform, "--edges", "normal,build",
         "--prefix", "none", "--format", "{p}"], text=True
    )
    reachable = {(parts[0], parts[1].removeprefix("v"))
                 for line in tree.splitlines() if len(parts := line.split()) >= 2}
    inventory = []
    for package in sorted(metadata["packages"], key=lambda item: (item["name"], item["version"])):
        if package["source"] is None or (package["name"], package["version"]) not in reachable:
            continue
        root = Path(package["manifest_path"]).parent
        copied = []
        for source in sorted(root.rglob("*")):
            if not source.is_file():
                continue
            name = source.name.upper()
            if not any(word in name for word in ("LICENSE", "LICENCE", "COPYING", "COPYRIGHT", "NOTICE", "UNLICENSE")):
                continue
            relative = source.relative_to(root)
            target = destination / f'{package["name"]}-{package["version"]}' / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            copied.append(str(relative))
        if package["license_file"]:
            source = root / package["license_file"]
            if str(source.relative_to(root)) not in copied:
                target = destination / f'{package["name"]}-{package["version"]}' / source.name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
                copied.append(source.name)
        if not copied:
            raise RuntimeError(f'No packaged license notice found for {package["name"]}')
        inventory.append({"name": package["name"], "version": package["version"],
                          "license": package["license"], "notices": copied})
    sysroot = Path(subprocess.check_output(["rustc", "--print", "sysroot"], text=True).strip())
    rust_notices = sysroot / "share/doc/rust"
    for name in ("LICENSE-MIT", "LICENSE-APACHE", "COPYRIGHT"):
        source = rust_notices / name
        if source.is_file():
            target = destination / "rust" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
    (destination / "inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")


if __name__ == "__main__":
    main()
