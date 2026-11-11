#!/usr/bin/env python3
"""Provision the existing production identity on an eligible Apple Silicon Mac.

Private material is decrypted only on that Mac and imported into a dedicated
non-synchronized keychain. Never run this on an installation-only Intel host.
"""
import argparse
import base64
import getpass
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('personal_release', ROOT / 'scripts/publish-icloud-update.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def secret_command(arguments, data=None):
    # Neither failures nor subprocess stderr may echo password-bearing arguments.
    result = subprocess.run(arguments, input=data, capture_output=True)
    if result.returncode:
        raise RuntimeError('Signing setup operation failed; no credential details were logged.')
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('prepare-migration', help='Generate a private recipient key locally; print only its public recipient')
    command = commands.add_parser('import-migration', help='Decrypt a one-time encrypted Actions artifact and import the identity')
    command.add_argument('encrypted_file', type=Path)
    command = commands.add_parser('import-p12', help='Import an existing private backup instead of using GitHub')
    command.add_argument('p12', type=Path)
    args = parser.parse_args()
    release.require_host()
    directory = Path.home() / 'Library/Application Support/Remarc Signing'
    directory.mkdir(mode=0o700, exist_ok=True)
    if directory.resolve() != directory:
        raise ValueError('The local signing directory cannot be a symbolic link.')
    os.chmod(directory, 0o700)
    recipient_key = directory / 'migration.agekey'
    if args.command == 'prepare-migration':
        if not shutil.which('age-keygen'):
            raise ValueError('Install the encryption tool first: brew install age')
        if not recipient_key.exists():
            secret_command(['age-keygen', '-o', str(recipient_key)])
        os.chmod(recipient_key, 0o600)
        recipient = secret_command(['age-keygen', '-y', str(recipient_key)]).decode().strip()
        print('Run the one-time migration workflow with this public recipient:')
        print('gh workflow run signing-migration.yml -R handsomeliuyang/Remarc --ref main -f recipient=' + recipient)
        print('Download only production-signing.age from the resulting artifact, then run:')
        print('python3 scripts/setup-production-signing.py import-migration /absolute/path/production-signing.age')
        return
    if args.command == 'import-migration':
        if not shutil.which('age') or not recipient_key.exists():
            raise ValueError('Run prepare-migration on this Mac first; its private recipient key must remain local.')
        payload = json.loads(secret_command(['age', '--decrypt', '-i', str(recipient_key), str(args.encrypted_file.resolve())]))
        p12 = base64.b64decode(payload['p12'], validate=True)
        password = payload['password']
    else:
        p12 = args.p12.read_bytes()
        password = getpass.getpass('Existing P12 password: ')
    identity = json.loads((ROOT / 'signing/identities.json').read_text())['production']
    keychain = Path(os.environ.get('REMARC_PRODUCTION_KEYCHAIN', str(Path.home() / 'Library/Keychains/RemarcProduction.keychain-db'))).expanduser().resolve()
    if ROOT in keychain.parents or Path.home() / 'Library/Mobile Documents' in keychain.parents:
        raise ValueError('The keychain must be outside repositories and iCloud.')
    tool = release.update_tool()
    with tempfile.TemporaryDirectory(prefix='remarc-signing-import-') as temporary:
        path = Path(temporary) / 'identity.p12'
        path.write_bytes(p12)
        path.chmod(0o600)
        certificate = secret_command(['/usr/bin/openssl', 'pkcs12', '-in', str(path), '-clcerts', '-nokeys', '-passin', 'stdin'], (password + '\n').encode())
        digest = secret_command(['/usr/bin/openssl', 'x509', '-noout', '-fingerprint', '-sha1'], certificate).decode().strip().split('=')[-1].replace(':', '')
        if digest != identity['sha1']:
            raise ValueError('The certificate does not match the existing pinned production identity. Nothing was imported.')
        exists = keychain.exists()
        keychain_password = getpass.getpass('Dedicated production keychain password' + (' (existing)' if exists else ' (choose a new password)') + ': ')
        if not keychain_password:
            raise ValueError('The dedicated keychain password cannot be empty.')
        if not exists:
            if getpass.getpass('Repeat new keychain password: ') != keychain_password:
                raise ValueError('Passwords differ.')
            secret_command(['security', 'create-keychain', '-p', keychain_password, str(keychain)])
        secret_command(['security', 'unlock-keychain', '-p', keychain_password, str(keychain)])
        secret_command(['security', 'set-keychain-settings', '-lut', '21600', str(keychain)])
        secret_command(['security', 'import', str(path), '-k', str(keychain), '-P', password, '-T', '/usr/bin/codesign', '-T', str(tool)])
        secret_command(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', keychain_password, str(keychain)])
    # Same shared trust policy used by the updater; checks that the private key exists too.
    release.run(tool, 'preflight', keychain)
    if args.command == 'import-migration':
        recipient_key.unlink()
    print('Existing production identity imported and verified. No trust settings or app permissions were reset.')
    print('Keep your encrypted backup separately. Delete the one-time Actions artifact after verifying the import.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError) as error:
        print('Signing setup stopped: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
