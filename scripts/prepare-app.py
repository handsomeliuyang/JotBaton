#!/usr/bin/env python3
"""Finalize bundle metadata/resources before applying its stable signature."""
import argparse
import base64
import json
import os
import plistlib
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('--channel', required=True, choices=['development', 'production'])
args = parser.parse_args()
if args.channel == 'production' and os.environ.get('GITHUB_ACTIONS') != 'true':
    parser.error('Production packages are built only by GitHub Actions; use dev-preview.sh locally.')
plist = args.app / 'Contents/Info.plist'
info = plistlib.loads(plist.read_bytes())
dev = args.channel == 'development'
info['CFBundleIdentifier'] = 'com.metepolat.Remarc.dev' if dev else 'com.metepolat.Remarc'
info['CFBundleName'] = info['CFBundleDisplayName'] = 'JotBaton Dev' if dev else 'JotBaton'
info['CFBundleURLTypes'] = [{'CFBundleURLName': info['CFBundleIdentifier'], 'CFBundleURLSchemes': ['remarc-dev' if dev else 'remarc']}]
info['RemarcManualUpdates'] = dev
info['RemarcGitHubUpdates'] = not dev
info['RemarcInAppUpdates'] = not dev
info.pop('RemarcCloudUpdates', None)
info.pop('SUFeedURL', None)
info.pop('SUPublicEDKey', None)
info['SUEnableAutomaticChecks'] = False
info['SUAutomaticallyUpdate'] = False
info['SUAllowsAutomaticUpdates'] = False
info['SUEnableSystemProfiling'] = False
info['SUVerifyUpdateBeforeExtraction'] = not dev
info['SURequireSignedFeed'] = not dev
if not dev:
    root = Path(__file__).resolve().parents[1]
    updates = json.loads((root / 'signing/updates.json').read_text())
    if len(base64.b64decode(updates['public_ed_key'], validate=True)) != 32:
        raise ValueError('Invalid pinned public update key')
    archs = subprocess.check_output(['lipo', '-archs', str(args.app / 'Contents/MacOS' / info['CFBundleExecutable'])], text=True).split()
    if archs not in (['arm64'], ['x86_64']):
        raise ValueError('Production updates require one native architecture per package')
    info['SUPublicEDKey'] = updates['public_ed_key']
    info['SUFeedURL'] = updates['feed_base_url'] + 'appcast-' + archs[0] + '.xml'
info['RemarcChannel'] = args.channel
info['RemarcSourceCommit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
plist.write_bytes(plistlib.dumps(info))
if dev:
    popclip = args.app / 'Contents/Resources/Remarc.popclipext/Config.ts'
    if popclip.exists():
        content = popclip.read_text().replace('com.metepolat.remarc.popclip', 'com.metepolat.remarc.dev.popclip')
        content = content.replace('["com.metepolat.Remarc"]', '["com.metepolat.Remarc.dev"]')
        content = content.replace('// name: JotBaton\n', '// name: JotBaton Dev\n').replace('name: JotBaton,', 'name: JotBaton Dev,')
        content = content.replace('remarc://comment', 'remarc-dev://comment')
        popclip.write_text(content)

# Remove the retired installer from reused development preview bundles.
helper = args.app / 'Contents/Helpers/RemarcUpdateInstaller'
helper.unlink(missing_ok=True)
