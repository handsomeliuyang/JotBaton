#!/usr/bin/env python3
"""Run native update trust/rollback checks without building the app or accessing a private production key."""
import base64
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / 'app/RemarcPackage/Sources/RemarcFeature/Services/CloudUpdatePolicy.swift'


def run(*args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if result.returncode:
        # Test certificates are ephemeral fixtures; never print their private bytes.
        raise RuntimeError(result.stderr or 'Update regression check failed')
    if result.stdout:
        print(result.stdout.strip())


with tempfile.TemporaryDirectory(prefix='remarc-update-tests-') as temporary:
    parent = Path(temporary)
    binary = parent / 'update-tests'
    run('xcrun', 'swiftc', CORE, ROOT / 'tests/updates/main.swift', '-o', binary)
    for algorithm in ('rsa-sha256', 'ecdsa-sha256'):
        directory = parent / algorithm
        directory.mkdir()
        key, certificate = directory / 'test.key', directory / 'test.pem'
        key_options = ['-newkey', 'rsa:2048'] if algorithm == 'rsa-sha256' else ['-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-pkeyopt', 'ec_param_enc:named_curve']
        run('/usr/bin/openssl', 'req', '-x509', *key_options, '-nodes', '-keyout', key,
            '-out', certificate, '-subj', '/CN=Ephemeral update test only', '-days', '1')
        key.chmod(0o600)
        der = directory / 'test.der'
        run('/usr/bin/openssl', 'x509', '-in', certificate, '-outform', 'DER', '-out', der)
        payload = b'archive test fixture'
        (directory / 'payload.zip').write_bytes(payload)
        packages = [dict(architecture=arch, minimumOS=minimum, filename=f'Remarc-1.2.23-42-2026-11-11_12-00-00-{arch}.zip',
                         sha256=hashlib.sha256(payload).hexdigest(), size=len(payload))
                    for arch, minimum in [('arm64', '14.0'), ('x86_64', '13.0')]]
        manifest = dict(format=1, version='1.2.23', build=42, sourceCommit='a' * 40,
                        publishedAt='2026-11-11T12:00:00Z', packages=packages)
        data = json.dumps(manifest).encode()
        (directory / 'manifest.json').write_bytes(data)
        signature = directory / 'test.sig'
        run('/usr/bin/openssl', 'dgst', '-sha256', '-sign', key, '-out', signature, directory / 'manifest.json')
        envelope = dict(format=1, algorithm=algorithm, payload=base64.b64encode(data).decode(),
                        signature=base64.b64encode(signature.read_bytes()).decode(), certificate=base64.b64encode(der.read_bytes()).decode())
        (directory / 'latest.json').write_text(json.dumps(envelope))
        print('Signature algorithm:', algorithm)
        run(binary, directory)
    for source in ['tools/update-installer/main.swift', 'tools/cloud-update/main.swift']:
        run('xcrun', 'swiftc', '-typecheck', CORE, ROOT / source)
    pinned = json.loads((ROOT / 'signing/identities.json').read_text())['production']['sha1']
    assert f'productionFingerprint = "{pinned}"' in CORE.read_text()
    print('Native installer/publisher type checks and production pin consistency passed.')
