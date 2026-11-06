#!/usr/bin/env python3
"""Verify both packaged apps before allowing a fork Release to be published."""
import hashlib
import os
import plistlib
import shutil
import subprocess
from pathlib import Path


def run(*args):
    subprocess.run(args, check=True)


def verify_app(app, verifier):
    run('python3', verifier, str(app))
    run('codesign', '--verify', '--deep', '--strict', str(app))
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    for key, expected in {
        'CFBundleShortVersionString': os.environ['VERSION'],
        'CFBundleVersion': os.environ['BUILD_NUMBER'],
        'RemarcSourceCommit': os.environ['SOURCE_SHA'],
        'RemarcManualUpdates': True,
    }.items():
        if info.get(key) != expected:
            raise ValueError(f'{app}: {key} is {info.get(key)!r}; expected {expected!r}')


def main():
    intel = Path('build/downloads/intel')
    arm = Path('build/downloads/arm64')
    for directory in (intel, arm):
        subprocess.run(['shasum', '-a', '256', '-c', 'SHA256SUMS'], cwd=directory, check=True)
    run('ditto', '-x', '-k', str(intel / 'Remarc-Ventura-x86_64.zip'), 'build/intel-verified')
    verify_app(Path('build/intel-verified/Remarc.app'), 'scripts/verify-ventura-app.py')
    dmg = arm / 'Remarc-Apple-Silicon-arm64.dmg'
    run('hdiutil', 'verify', str(dmg))
    mount = Path('build/arm64-mounted').resolve()
    run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(dmg))
    try:
        verify_app(mount / 'Remarc.app', 'scripts/verify-apple-silicon-app.py')
    finally:
        run('hdiutil', 'detach', str(mount))
    output = Path('build/release')
    output.mkdir(parents=True, exist_ok=False)
    shutil.copy2(intel / 'Remarc-Ventura-x86_64.zip', output)
    shutil.copy2(dmg, output)
    # Ship the Intel signing helper with its exact relative dependencies.
    helpers = Path('build/ventura-install-tools')
    for relative in ('scripts/sign-ventura-local.sh', 'scripts/verify-ventura-app.py', 'app/Config/Ventura.entitlements'):
        destination = helpers / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(relative, destination)
    run('ditto', '-c', '-k', '--keepParent', str(helpers), str(output / 'Remarc-Ventura-Install-Tools.zip'))
    instructions = f'''Remarc {os.environ['VERSION']} ({os.environ['BUILD_NUMBER']})
Source commit: {os.environ['SOURCE_SHA']}

黑苹果 / Intel (macOS 13+):
1. 解压 Remarc-Ventura-x86_64.zip 和 Remarc-Ventura-Install-Tools.zip。
2. 在终端执行 bash /完整路径/ventura-install-tools/scripts/sign-ventura-local.sh /完整路径/Remarc.app
   这会在本机创建/复用专用签名证书，并添加当前用户的代码签名信任。
3. 退出旧版 Remarc，将重新签名的 Remarc.app 放入 /Applications，替换旧版本并打开。
   如已有旧版，建议先备份。现有评论保存在用户 Library/Application Support/Remarc 中。

M5 Pro / Apple Silicon (macOS 14+):
打开 Remarc-Apple-Silicon-arm64.dmg，将 Remarc.app 拖入 Applications 后打开。
保留完整语音后端；语音功能需要 macOS 26。

两个版本均未经过 Apple 公证。首次打开被拦截时，前往“系统设置 → 隐私与安全性 → 仍要打开”。
https://support.apple.com/en-us/102445
根据提示授予辅助功能、屏幕录制等所需权限。两个版本均需手动更新。
在下载目录运行 shasum -a 256 -c SHA256SUMS 校验文件完整性。
'''
    (output / 'INSTALL.txt').write_text(instructions)
    sums = ''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in sorted(output.iterdir()))
    (output / 'SHA256SUMS').write_text(sums)


if __name__ == '__main__':
    main()
