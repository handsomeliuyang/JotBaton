#!/usr/bin/env python3
"""Finalize bundle metadata/resources before applying its stable signature."""
import argparse
import plistlib
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('--channel', required=True, choices=['development', 'production'])
args = parser.parse_args()
plist = args.app / 'Contents/Info.plist'
info = plistlib.loads(plist.read_bytes())
dev = args.channel == 'development'
info['CFBundleIdentifier'] = 'com.metepolat.Remarc.dev' if dev else 'com.metepolat.Remarc'
info['CFBundleName'] = info['CFBundleDisplayName'] = 'Remarc Dev' if dev else 'Remarc'
info['CFBundleURLTypes'] = [{'CFBundleURLName': info['CFBundleIdentifier'], 'CFBundleURLSchemes': ['remarc-dev' if dev else 'remarc']}]
info['RemarcManualUpdates'] = True
info['SUEnableAutomaticChecks'] = False
info['RemarcChannel'] = args.channel
info['RemarcSourceCommit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
plist.write_bytes(plistlib.dumps(info))
if dev:
    script = args.app / 'Contents/Resources/remarc-mcp.js'
    source = script.read_text()
    replacements = {
        '"Application Support", "Remarc"': '"Application Support", "Remarc Dev"',
        'com.metepolat.Remarc.reload': 'com.metepolat.Remarc.dev.reload',
        'remarc-claude-': 'remarc-dev-claude-',
    }
    for old, new in replacements.items():
        if old not in source:
            raise ValueError('Bundled MCP storage contract changed: ' + old)
        source = source.replace(old, new)
    script.write_text(source)
    print('Prepared isolated development MCP storage and notifications')

    popclip = args.app / 'Contents/Resources/Remarc.popclipext/Config.ts'
    if popclip.exists():
        content = popclip.read_text().replace('com.metepolat.remarc.popclip', 'com.metepolat.remarc.dev.popclip')
        content = content.replace('com.metepolat.Remarc', 'com.metepolat.Remarc.dev')
        content = content.replace('// name: Remarc', '// name: Remarc Dev').replace('name: Remarc,', 'name: Remarc Dev,')
        content = content.replace('remarc://comment', 'remarc-dev://comment')
        popclip.write_text(content)
