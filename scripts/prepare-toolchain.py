#!/usr/bin/env python3
"""Create a project-local VFS overlay for duplicate CLT SwiftBridging maps."""
import json
from pathlib import Path
import re
import subprocess

layout_switcher_root = Path(__file__).resolve().parent.parent
swiftc = Path(subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip())
headers = swiftc.parent.parent / "include" / "swift"
old, current = headers / "module.modulemap", headers / "bridging.modulemap"
directory = layout_switcher_root / ".build" / "toolchain"
directory.mkdir(parents=True, exist_ok=True)
empty = directory / "empty-module.modulemap"
empty.write_text("// Duplicate obsolete SwiftBridging map hidden in this project build only.\n")
roots = []
if old.is_file() and current.is_file():
    def body(path):
        return re.sub(r"\s+", "", re.sub(r"//[^\n]*", "", path.read_text()))
    if body(old) == body(current) and "moduleSwiftBridging{" in body(old):
        roots.append({"type": "file", "name": str(old), "external-contents": str(empty)})
overlay = directory / "swift-bridging-overlay.json"
overlay.write_text(json.dumps({"version": 0, "roots": roots}, indent=2) + "\n")
print(overlay)
