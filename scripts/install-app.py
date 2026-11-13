#!/usr/bin/env python3
"""Verify and install a native signed package without changing its signature."""
import argparse
import json
import os
import platform
import plistlib
import shutil
import subprocess
import time
import uuid
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('--channel', required=True, choices=['production', 'development'])
parser.add_argument('--keep-one-backup', action='store_true', help='Keep only the previous production app/data backup for release installations')
parser.add_argument('--skip-diagnostics', action='store_true', help='Launch normally without requesting a diagnostic report (always used for production)')
parser.add_argument('--reset-permissions', action='store_true', help='Reset only this channel’s Accessibility and ScreenCapture grants for a certificate migration')
args = parser.parse_args()
# Production updates end with a normal launch; post-install diagnostics are disabled by policy.
args.skip_diagnostics = args.skip_diagnostics or args.channel == 'production'
if args.keep_one_backup and args.channel != 'production':
    parser.error('--keep-one-backup is for production release installations only')
app = args.app.resolve()
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
identity = json.loads((ROOT / 'signing/identities.json').read_text())[args.channel]
subprocess.run(['python3', str(ROOT / 'scripts/sign-app.py'), str(app), '--channel', args.channel, '--verify-only'], check=True)
arch = platform.machine()
binary = app / 'Contents/MacOS' / info['CFBundleExecutable']
if arch not in subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split():
    raise ValueError('Package does not support the current machine architecture')
verifier = 'verify-ventura-app.py' if arch == 'x86_64' else 'verify-apple-silicon-app.py'
subprocess.run(['python3', str(ROOT / 'scripts' / verifier), str(app)], check=True)
name = 'JotBaton Dev' if args.channel == 'development' else 'JotBaton'
storage_name = 'Remarc Dev' if args.channel == 'development' else 'Remarc'
destination = Path('/Applications') / (name + '.app')
installed = destination
legacy = destination.parent / (storage_name + '.app')
if not destination.exists() and legacy.exists():
    legacy_info = plistlib.loads((legacy / 'Contents/Info.plist').read_bytes())
    if legacy_info.get('CFBundleIdentifier') != identity['bundle_id']:
        raise ValueError('The legacy installation belongs to a different channel')
    # Retire only this channel's previously signed installation, after backing it up.
    subprocess.run(['python3', str(ROOT / 'scripts/sign-app.py'), str(legacy), '--channel', args.channel, '--verify-only'], check=True)
    installed = legacy
if app in (destination, installed):
    raise ValueError('Install from a separate extracted package, preserving the installed app for rollback')
backup = Path.home() / 'Library/Application Support/Remarc Install Backups' / (datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + args.channel)
if args.keep_one_backup:
    backup = Path.home() / 'Library/Application Support/Remarc Update Backups' / ('.pending-' + str(uuid.uuid4()))
backup.mkdir(parents=True)
subprocess.run(['pkill', '-x', info['CFBundleExecutable']], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1)
try:
    if installed.exists():
        subprocess.run(['ditto', str(installed), str(backup / installed.name)], check=True)
    data = Path.home() / 'Library/Application Support' / storage_name
    if data.exists():
        subprocess.run(['ditto', str(data), str(backup / 'user-data')], check=True)
except BaseException:
    if installed.exists():
        subprocess.run(['open', str(installed)])
    raise


stage = destination.parent / ('.remarc-install-' + str(uuid.uuid4()) + '.app')
previous = destination.parent / ('.remarc-previous-' + str(uuid.uuid4()) + '.app')
try:
    subprocess.run(['ditto', str(app), str(stage)], check=True)
    subprocess.run(['python3', str(ROOT / 'scripts/sign-app.py'), str(stage), '--channel', args.channel, '--verify-only'], check=True)
    if installed.exists():
        os.rename(installed, previous)
    os.rename(stage, destination)
    if args.reset_permissions:
        for service in ['Accessibility', 'ScreenCapture']:
            subprocess.run(['tccutil', 'reset', service, identity['bundle_id']], check=True)
    report = '/tmp/remarc-' + args.channel + '-diagnostics.json'
    launch_arguments = [] if args.skip_diagnostics else ['--diagnostics-output', report]
    subprocess.run(['python3', str(ROOT / 'scripts/relaunch-app.py'), str(destination), *launch_arguments], check=True)
except BaseException:
    if previous.exists():
        if destination.exists():
            shutil.rmtree(destination)
        os.rename(previous, installed)
        subprocess.run(['open', str(installed)])
    raise
finally:
    if stage.exists():
        shutil.rmtree(stage)
if previous.exists():
    shutil.rmtree(previous)
if args.keep_one_backup:
    retained = backup.parent / 'Previous'
    retired = backup.parent / ('.retired-' + str(uuid.uuid4()))
    if retained.exists():
        os.rename(retained, retired)
    try:
        os.rename(backup, retained)
    except BaseException:
        if retired.exists():
            os.rename(retired, retained)
        raise
    if retired.exists():
        shutil.rmtree(retired)
    backup = retained
print('Installed without re-signing: ' + str(destination))
print('Rollback app and user data: ' + str(backup))
if not args.skip_diagnostics:
    print('Installation diagnostics: ' + report)
