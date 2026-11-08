#!/usr/bin/env python3
"""Validate a new fork release or resume its exact version commit."""
import os
import re
import subprocess
from pathlib import Path


def validate_version(current_version, current_build, version, build, subject):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("Version must be X.Y.Z without leading zeroes")
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("Build number must be a positive integer")
    if version == current_version and build == current_build:
        if subject != f"Release v{version}":
            raise ValueError("Only the exact release version commit may be resumed")
        return
    if tuple(map(int, version.split('.'))) <= tuple(map(int, current_version.split('.'))):
        raise ValueError("Marketing version must increase")
    if int(build) <= int(current_build):
        raise ValueError("Build number must increase")


def main():
    version, build = os.environ['VERSION'], os.environ['BUILD_NUMBER']
    if not os.environ['NOTES'].strip():
        raise ValueError("Release notes cannot be empty")
    path = Path('app/Config/Shared.xcconfig')
    text = path.read_text()
    current_version = re.findall(r'^MARKETING_VERSION = (\S+)$', text, re.M)
    current_build = re.findall(r'^CURRENT_PROJECT_VERSION = (\d+)$', text, re.M)
    if len(current_version) != 1 or len(current_build) != 1:
        raise ValueError("Expected exactly one version and build field")
    subject = subprocess.check_output(['git', 'log', '-1', '--format=%s'], text=True).strip()
    validate_version(current_version[0], current_build[0], version, build, subject)
    text = re.sub(r'^MARKETING_VERSION = .*$', f'MARKETING_VERSION = {version}', text, flags=re.M)
    text = re.sub(r'^CURRENT_PROJECT_VERSION = .*$', f'CURRENT_PROJECT_VERSION = {build}', text, flags=re.M)
    path.write_text(text)


if __name__ == '__main__':
    main()
