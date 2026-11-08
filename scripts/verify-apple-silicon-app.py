#!/usr/bin/env python3
"""Verify native Apple Silicon code and the standard macOS 14 deployment floor."""
import plistlib
import re
import subprocess
import sys
from pathlib import Path

app = Path(sys.argv[1]).resolve()
with (app / "Contents/Info.plist").open("rb") as handle:
    info = plistlib.load(handle)
assert info["CFBundleIdentifier"] == "com.metepolat.Remarc"
assert info["LSMinimumSystemVersion"] in ("14.0", "14.0.0")
assert info["RemarcManualUpdates"] is True
assert re.fullmatch(r"[0-9a-f]{40}", info["RemarcSourceCommit"])

checked = 0
for path in app.rglob("*"):
    if not path.is_file() or path.is_symlink():
        continue
    if "Mach-O" not in subprocess.check_output(["file", "-b", str(path)], text=True):
        continue
    archs = subprocess.check_output(["lipo", "-archs", str(path)], text=True).split()
    assert "arm64" in archs, f"Missing Apple Silicon slice: {path}"
    commands = subprocess.check_output(["otool", "-arch", "arm64", "-l", str(path)], text=True)
    versions = re.findall(r"\bminos\s+([\d.]+)", commands)
    versions += re.findall(r"LC_VERSION_MIN_MACOSX\s+cmdsize\s+\d+\s+version\s+([\d.]+)", commands)
    assert versions, f"Missing deployment version: {path}"
    for version in versions:
        parts = tuple(int(part) for part in version.split("."))
        assert (parts + (0, 0))[:3] <= (14, 0, 0), f"{path} requires macOS {version}"
    checked += 1
assert checked, "No Mach-O images found"
print(f"Verified {checked} Mach-O images: arm64, macOS 14.0 or earlier; app minimum 14.0")
