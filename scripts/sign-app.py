#!/usr/bin/env python3
"""Sign an app with its pinned channel identity; never generate or fall back.

Development credentials are deliberately shared test fixtures in this repo.
Production credentials exist only in Actions Secrets and this process's temp dir.
"""
import argparse
import base64
import json
import os
import plistlib
import secrets
import shlex
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*args, input=None):
    result = subprocess.run(args, input=input, capture_output=True)
    if result.returncode:
        # Arguments may contain passwords. Do not echo command lines or output.
        raise RuntimeError(f'{args[0]} failed (exit {result.returncode})')
    return result.stdout


def validate_identity(app, channel, config):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    expected = config[channel]
    if info.get('CFBundleIdentifier') != expected['bundle_id']:
        raise ValueError('Bundle ID does not match the selected signing channel')
    if info.get('CFBundleURLTypes', [{}])[0].get('CFBundleURLSchemes') != [expected['url_scheme']]:
        raise ValueError('URL scheme does not match the selected signing channel')
    return expected


def verify(app, channel, config):
    expected = validate_identity(app, channel, config)
    requirement = f'identifier "{expected["bundle_id"]}" and certificate leaf = H"{expected["sha1"]}"'
    run('codesign', '--verify', '--deep', '--strict', '-R=' + requirement, str(app))
    print(f'Verified stable {channel} signing identity: {expected["sha1"]}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--channel', choices=['development', 'production'], required=True)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    app = args.app.resolve()
    config = json.loads((ROOT / 'signing/identities.json').read_text())
    expected = validate_identity(app, args.channel, config)
    if args.verify_only:
        verify(app, args.channel, config)
        return
    if args.channel == 'development':
        p12 = (ROOT / 'signing/development.p12').read_bytes()
        password = (ROOT / 'signing/development-password.txt').read_text().strip()
    else:
        if os.environ.get('GITHUB_ACTIONS') != 'true':
            raise ValueError('Production signing is restricted to GitHub Actions')
        p12 = base64.b64decode(os.environ['REMARC_SIGNING_P12_BASE64'], validate=True)
        password = os.environ['REMARC_SIGNING_P12_PASSWORD']
    original = shlex.split(run('security', 'list-keychains', '-d', 'user').decode())
    with tempfile.TemporaryDirectory(prefix='remarc-sign-') as directory:
        temp = Path(directory)
        keychain = str(temp / 'signing.keychain-db')
        keychain_password = secrets.token_hex(32)
        certificate = temp / 'identity.p12'
        certificate.write_bytes(p12)
        certificate.chmod(0o600)
        try:
            run('security', 'create-keychain', '-p', keychain_password, keychain)
            run('security', 'set-keychain-settings', '-lut', '21600', keychain)
            run('security', 'unlock-keychain', '-p', keychain_password, keychain)
            run('security', 'import', str(certificate), '-k', keychain, '-P', password, '-T', '/usr/bin/codesign')
            run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', keychain_password, keychain)
            # The signing identity is selected by fingerprint, not a mutable name.
            exported = run('security', 'find-certificate', '-c', expected['name'], '-p', keychain)
            cert_file = temp / 'certificate.pem'
            cert_file.write_bytes(exported)
            digest = run('/usr/bin/openssl', 'x509', '-noout', '-fingerprint', '-sha1', '-in', str(cert_file)).decode().strip().split('=')[-1].replace(':', '')
            if digest != expected['sha1']:
                raise ValueError('Imported certificate fingerprint does not match the pinned identity')
            run('security', 'add-trusted-cert', '-r', 'trustRoot', '-p', 'codeSign', '-k', keychain, str(cert_file))
            run('security', 'list-keychains', '-d', 'user', '-s', *dict.fromkeys([*original, keychain]))
            # Sign nested code from the inside out, preserving independent bundle IDs.
            for path in sorted(app.rglob('*'), key=lambda p: len(p.parts), reverse=True):
                if path.is_symlink():
                    continue
                is_bundle = path.is_dir() and path.suffix in ('.app', '.framework', '.xpc')
                is_code = path.is_file() and b'Mach-O' in run('file', '-b', str(path))
                if is_bundle or is_code:
                    run('codesign', '--force', '--sign', expected['sha1'], '--keychain', keychain, '--timestamp=none', str(path))
            run('codesign', '--force', '--sign', expected['sha1'], '--keychain', keychain,
                '--timestamp=none', '--entitlements', str(ROOT / 'app/Config/Ventura.entitlements'), str(app))
            verify(app, args.channel, config)
        finally:
            run('security', 'list-keychains', '-d', 'user', '-s', *original)
            subprocess.run(['security', 'delete-keychain', keychain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == '__main__':
    main()
