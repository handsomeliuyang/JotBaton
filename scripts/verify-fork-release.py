#!/usr/bin/env python3
"""Verify both packaged apps before allowing a fork Release to be published."""
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
from pathlib import Path


def run(*args):
    subprocess.run(args, check=True)


def verify_app(app, verifier):
    run('python3', verifier, str(app))
    run('python3', 'scripts/sign-app.py', str(app), '--channel', 'production', '--verify-only')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('RemarcCloudUpdates') or (app / 'Contents/Helpers/RemarcUpdateInstaller').exists():
        raise ValueError('Retired iCloud software updater remains in the release package')
    for key, expected in {
        'CFBundleIdentifier': 'com.metepolat.Remarc',
        'CFBundleName': 'JotBaton',
        'CFBundleDisplayName': 'JotBaton',
        'RemarcChannel': 'production',
        'CFBundleShortVersionString': os.environ['VERSION'],
        'CFBundleVersion': os.environ['BUILD_NUMBER'],
        'RemarcSourceCommit': os.environ['SOURCE_SHA'],
        'RemarcManualUpdates': False,
        'RemarcGitHubUpdates': True,
        'RemarcInAppUpdates': True,
        'SUPublicEDKey': json.loads(Path('signing/updates.json').read_text())['public_ed_key'],
        'SUEnableAutomaticChecks': False,
        'SUAutomaticallyUpdate': False,
        'SUAllowsAutomaticUpdates': False,
        'SUVerifyUpdateBeforeExtraction': True,
        'SURequireSignedFeed': True,
    }.items():
        if info.get(key) != expected:
            raise ValueError(f'{app}: {key} is {info.get(key)!r}; expected {expected!r}')
    arch = 'x86_64' if verifier.endswith('verify-ventura-app.py') else 'arm64'
    updates = json.loads(Path('signing/updates.json').read_text())
    if info.get('SUFeedURL') != updates['feed_base_url'] + f'appcast-{arch}.xml':
        raise ValueError('The update feed does not match this package architecture')
    sparkle = app / 'Contents/Frameworks/Sparkle.framework'
    for helper in ['Updater.app/Contents/MacOS/Updater', 'Autoupdate']:
        if not (sparkle / 'Versions/B' / helper).is_file():
            raise ValueError('Missing Sparkle installation helper: ' + helper)


def main():
    intel = Path('build/downloads/intel')
    arm = Path('build/downloads/arm64')
    for directory in (intel, arm):
        subprocess.run(['shasum', '-a', '256', '-c', 'SHA256SUMS'], cwd=directory, check=True)
    run('ditto', '-x', '-k', str(intel / 'Remarc-Ventura-x86_64.zip'), 'build/intel-verified')
    verify_app(Path('build/intel-verified/JotBaton.app'), 'scripts/verify-ventura-app.py')
    dmg = arm / 'Remarc-Apple-Silicon-arm64.dmg'
    run('hdiutil', 'verify', str(dmg))
    mount = Path('build/arm64-mounted').resolve()
    run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(dmg))
    try:
        verify_app(mount / 'JotBaton.app', 'scripts/verify-apple-silicon-app.py')
    finally:
        run('hdiutil', 'detach', str(mount))
    output = Path('build/release')
    output.mkdir(parents=True, exist_ok=False)
    shutil.copy2(intel / 'Remarc-Ventura-x86_64.zip', output)
    shutil.copy2(dmg, output)
    instructions = f'''JotBaton {os.environ['VERSION']} ({os.environ['BUILD_NUMBER']})
Source commit: {os.environ['SOURCE_SHA']}

黑苹果 / Intel (macOS 13+):
解压 Remarc-Ventura-x86_64.zip，退出旧版，将 JotBaton.app 替换到 /Applications 后打开。
Apple Silicon (macOS 14+):
打开 Remarc-Apple-Silicon-arm64.dmg，将 JotBaton.app 拖入 Applications 后打开。
两个架构使用同一个固定私有发布证书，无需本机重新签名。
首次迁移到此发布证书时，请重新授予辅助功能、屏幕录制等权限；后续更新持续复用此身份。
如已有旧版，先备份应用。保留现有用户数据，不要删除 Library/Application Support/Remarc。

JotBaton Dev 使用独立测试证书、com.metepolat.Remarc.dev 和 DEV 图标，可与正式版同时安装。
本地数据：正式版 Application Support/Remarc；测试版 Application Support/Remarc Dev。
iCloud：正式版 iCloud Drive/Remarc；测试版 iCloud Drive/Remarc Dev。两版不会自动迁移或共用同步数据。
两台 Mac 需要分别授权；签名一致不会跨电脑同步 macOS 权限。
接入应用内升级的正式版可点击“升级并重启”，自动下载、校验、安装并重启；旧版需最后手动升级一次。测试版保持独立；均未经过 Apple 公证。
首次打开被拦截时，前往“系统设置 → 隐私与安全性 → 仍要打开”。
https://support.apple.com/en-us/102445
在下载目录运行 shasum -a 256 -c SHA256SUMS 校验文件完整性。
'''
    (output / 'INSTALL.txt').write_text(instructions)
    sums = ''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in sorted(output.iterdir()))
    (output / 'SHA256SUMS').write_text(sums)


if __name__ == '__main__':
    main()
