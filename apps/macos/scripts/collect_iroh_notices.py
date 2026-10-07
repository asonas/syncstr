"""Collect notices from the Swift package's pinned Rust source release."""
import json
from pathlib import Path
import subprocess
import sys

source = Path(sys.argv[1])
expected = "5e451092dba0c1a09ee83ff6e5be37b1152a5c58"
actual = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
if actual != expected:
    raise RuntimeError("Use the iroh-ffi v1.1.0 source checkout")

def cargo(*args):
    return subprocess.check_output(["cargo", *args], cwd=source, text=True)

packages = {}
reachable = set()
for target in ("aarch64-apple-darwin", "aarch64-apple-ios"):
    metadata = json.loads(cargo("metadata", "--locked", "--format-version", "1", "--filter-platform", target))
    packages.update({(p["name"], p["version"]): p for p in metadata["packages"]})
    tree = cargo("tree", "--locked", "--target", target, "--edges", "normal,build", "--prefix", "none", "--format", "{p}", "-p", "iroh-ffi")
    reachable.update((parts[0], parts[1].removeprefix("v")) for line in tree.splitlines() if len(parts := line.split()) >= 2)

sections = ["IrohLib 1.1.0 and packaged dependencies\nSource: https://github.com/n0-computer/iroh-ffi/tree/v1.1.0\n"]
for key in sorted(reachable):
    package = packages[key]
    root = Path(package["manifest_path"]).parent
    notices = [p for p in sorted(root.rglob("*")) if p.is_file() and any(word in p.name.upper() for word in ("LICENSE", "LICENCE", "COPYING", "COPYRIGHT", "NOTICE", "UNLICENSE"))]
    texts = []
    for path in notices:
        texts.append(str(path.relative_to(root)) + "\n" + path.read_text(errors="replace"))
    if not texts and package["license"] in ("MIT OR Apache-2.0", "Apache-2.0 OR MIT", "Apache-2.0/MIT"):
        texts.append("The crate manifest offers Apache-2.0. No separate notice is packaged.\n"
            + "Repository: " + package["repository"] + "\nAuthors: " + ", ".join(package["authors"]) + "\n"
            + (source / "LICENSE-APACHE").read_text())
    if not texts:
        if package["repository"] not in ("https://github.com/madsmtm/objc2", "https://github.com/mozilla/uniffi-rs"):
            raise RuntimeError(f"Missing packaged notice: {key}")
        revision = json.loads((root / ".cargo_vcs_info.json").read_text())["git"]["sha1"]
        repository = package["repository"].removeprefix("https://github.com/")
        entries = json.loads(subprocess.check_output(["gh", "api", f"repos/{repository}/contents?ref={revision}"], text=True))
        for item in entries:
            if item["type"] == "file" and "LICENSE" in item["name"].upper():
                notice = subprocess.check_output(["gh", "api", f"repos/{repository}/contents/{item['name']}?ref={revision}", "-H", "Accept: application/vnd.github.raw+json"], text=True)
                texts.append(item["name"] + " from the crate source revision " + revision + "\n" + notice)
        if not texts:
            raise RuntimeError(f"Missing upstream notice: {key}")
    sections.append(f"\n{'=' * 72}\n{key[0]} {key[1]} — {package['license']}\nSource: {package['repository']}\n" + "\n".join(texts))
output = "\n".join(sections)
repository = Path(__file__).resolve().parents[3]
for app in ("macos", "ios"):
    (repository / "apps" / app / "Licenses" / "IrohLib.txt").write_text(output)
