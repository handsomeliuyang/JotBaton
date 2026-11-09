#!/usr/bin/env python3
"""Seed the pinned Sparkle ZIP cache using curl and its upstream SHA-256.

SwiftPM 6.2's download-to-cache path can collide with its own destination on
hosted runners. A verified existing cache entry bypasses that download path.
The dependency version and its normal SwiftPM checksum validation stay intact.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
pins = json.loads((root / 'app/RemarcPackage/Package.resolved').read_text())['pins']
sparkle = next(pin for pin in pins if pin['identity'] == 'sparkle')
if sparkle['state'].get('version') != '2.9.5':
    raise ValueError('Update the verified binary cache metadata when changing Sparkle')
url = 'https://github.com/sparkle-project/Sparkle/releases/download/2.9.5/Sparkle-for-Swift-Package-Manager.zip'
# https://github.com/sparkle-project/Sparkle/blob/2.9.5/Package.swift
checksum = '34b9b2071f3de0012eca3faa3a9290bb94e62131e9a74f6dc91514a000097a6c'
directory = Path(sys.argv[1]).resolve() / 'artifacts'
directory.mkdir(parents=True, exist_ok=True)
destination = directory / re.sub(r'[^A-Za-z0-9_]', '_', url)
if not destination.is_file() or hashlib.sha256(destination.read_bytes()).hexdigest() != checksum:
    with tempfile.NamedTemporaryFile(dir=directory, prefix='.sparkle-', delete=False) as handle:
        temporary = Path(handle.name)
    try:
        subprocess.run(['curl', '--fail', '--silent', '--show-error', '--location', '--retry', '3',
                        '--connect-timeout', '20', '--max-time', '180', '--output', str(temporary), url], check=True)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != checksum:
            raise ValueError('Sparkle artifact checksum mismatch; refusing to seed cache')
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
print('Verified pinned Sparkle 2.9.5 binary cache (SHA-256 matches upstream manifest)')
