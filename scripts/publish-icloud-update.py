#!/usr/bin/env python3
"""Build both personal production packages on a capable Apple Silicon Mac.

No GitHub dispatch, remote signing, model-specific hostnames or private key files.
"""
import argparse
import base64
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / 'app/RemarcPackage/Sources/RemarcFeature/Services/CloudUpdatePolicy.swift'


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def output(*args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()


def require_host():
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise ValueError('Build on an Apple Silicon Mac; Ventura Intel is an installation/test host only.')
    version = output('xcodebuild', '-version').splitlines()[0].split()[-1]
    if tuple(map(int, version.split('.'))) < (26, 2):
        raise ValueError('Select full Xcode 26.2 or later with xcode-select before publishing.')
    # Check the selected compiler too; an independently selected old toolchain must fail early.
    swift = output('xcrun', 'swiftc', '--version')
    match = re.search(r'Swift version (\d+)\.(\d+)', swift)
    if not match or tuple(map(int, match.groups())) < (6, 2):
        raise ValueError('The selected Swift compiler must be 6.2 or later.')


def update_tool():
    binary = ROOT / 'app/DerivedData/UpdateTools/cloud-update'
    sources = [CORE, ROOT / 'tools/cloud-update/main.swift']
    binary.parent.mkdir(parents=True, exist_ok=True)
    if not binary.exists() or any(p.stat().st_mtime > binary.stat().st_mtime for p in sources):
        run('xcrun', 'swiftc', '-O', *sources, '-o', binary)
    return binary


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def wait_uploaded(tool, paths, timeout):
    deadline = time.monotonic() + timeout
    pending = list(paths)
    while pending:
        remaining = []
        for path in pending:
            state = output(tool, 'upload-state', path)
            if state == 'not-cloud':
                raise ValueError('The output folder is not an active iCloud Drive location.')
            if state != 'uploaded':
                remaining.append(path)
        pending = remaining
        if pending:
            if time.monotonic() >= deadline:
                raise TimeoutError('iCloud upload is not confirmed. The previous update remains usable; rerun with --resume.')
            print('Waiting for iCloud upload:', ', '.join(p.name for p in pending), flush=True)
            time.sleep(5)


def install_native(tool, directory, manifest):
    import tempfile
    native = next(p for p in manifest['packages'] if p['architecture'] == 'arm64')
    archive = directory / native['filename']
    if not archive.exists() or sha256(archive) != native['sha256']:
        raise ValueError('The retained ARM package is missing or changed; recover the exact verified cloud package before resuming.')
    with tempfile.TemporaryDirectory(prefix='remarc-native-install-') as temporary:
        run('ditto', '-x', '-k', archive, temporary)
        app = Path(temporary) / 'Remarc.app'
        run(tool, 'verify-app', directory / 'latest.json', app, 'arm64')
        run('python3', ROOT / 'scripts/install-app.py', app, '--channel', 'production', '--keep-one-backup')


def swift_tests(directory, commit):
    marker = directory / 'tests.commit'
    if marker.exists() and marker.read_text() == commit:
        return
    run('python3', ROOT / 'scripts/test-cloud-updates.py')
    package = ROOT / 'app/RemarcPackage'
    lock = package / 'Package.resolved'
    original = lock.read_bytes()
    try:
        for profile, ventura in [('standard', '0'), ('ventura', '1')]:
            env = {**os.environ, 'REMARC_VENTURA': ventura}
            env.pop('THREADS_ACCESS_TOKEN', None)
            run('bash', ROOT / 'scripts/resolve-packages.sh', package, env=env)
            run('xcrun', 'swift', 'test', '--package-path', package,
                '--cache-path', ROOT / 'app/DerivedData/PackageCache',
                '--scratch-path', ROOT / 'app/DerivedData/PersonalTests' / profile, env=env)
    finally:
        lock.write_bytes(original)
    marker.write_text(commit)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', help='New X.Y.Z; defaults to the next patch version')
    parser.add_argument('--build-number', type=int, help='Defaults to the next build number')
    parser.add_argument('--resume', action='store_true', help='Resume the exact clean release commit after a failed personal build/upload')
    parser.add_argument('--upload-timeout', type=int, default=1800)
    args = parser.parse_args()
    require_host()
    if not __import__('shutil').which('node'):
        raise ValueError('Install Node.js for packaged MCP checks before publishing.')
    os.chdir(ROOT)
    if output('git', 'branch', '--show-current') != 'main' or output('git', 'status', '--porcelain'):
        raise ValueError('Use a clean main checkout; commit accepted changes before building.')
    tool = update_tool()
    keychain = Path(os.environ.get('REMARC_PRODUCTION_KEYCHAIN', str(Path.home() / 'Library/Keychains/RemarcProduction.keychain-db'))).expanduser().resolve()
    if ROOT in keychain.parents or Path.home() / 'Library/Mobile Documents' in keychain.parents:
        raise ValueError('The production keychain must be outside repositories and iCloud.')
    run(tool, 'preflight', keychain)
    drive = Path.home() / 'Library/Mobile Documents/com~apple~CloudDocs'
    if not drive.is_dir() or output(tool, 'upload-state', drive) == 'not-cloud':
        raise ValueError('Enable iCloud Drive and wait for it to become available.')
    cloud = drive / 'Remarc/Updates'
    if cloud.resolve() != cloud:
        raise ValueError('The update directory cannot contain symlinks.')
    cloud.mkdir(parents=True, exist_ok=True)
    previous_file = cloud / 'latest.json'
    previous = None
    expected = '-'
    if previous_file.exists() or (cloud / '.latest.json.icloud').exists():
        local_previous = ROOT / 'app/DerivedData/UpdateTools/previous.json'
        run(tool, 'cloud-read', previous_file, local_previous)
        run(tool, 'verify', local_previous)
        previous = json.loads(base64.b64decode(json.loads(local_previous.read_text())['payload']))
        expected = sha256(local_previous)
    config = ROOT / 'app/Config/Shared.xcconfig'
    text = config.read_text()
    current = re.search(r'^MARKETING_VERSION = (\S+)$', text, re.M).group(1)
    current_build = int(re.search(r'^CURRENT_PROJECT_VERSION = (\d+)$', text, re.M).group(1))
    if args.resume:
        version, build = current, current_build
        if output('git', 'log', '-1', '--format=%s') != f'Release v{version}':
            raise ValueError('--resume requires the exact release version commit.')
        if args.version not in (None, version) or args.build_number not in (None, build):
            raise ValueError('Resume inputs must match the current version commit.')
    else:
        parts = list(map(int, current.split('.')))
        parts[2] += 1
        version = args.version or '.'.join(map(str, parts))
        build = args.build_number or current_build + 1
        if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
            raise ValueError('Version must be X.Y.Z.')
        if tuple(map(int, version.split('.'))) <= tuple(map(int, current.split('.'))) or build <= current_build:
            raise ValueError('Both the marketing version and build number must increase.')
    if previous and previous['build'] >= build:
        if args.resume and previous['build'] == build and previous['sourceCommit'] == output('git', 'rev-parse', 'HEAD'):
            directory = ROOT / f'app/DerivedData/PersonalReleases/v{version}-{build}'
            directory.mkdir(parents=True, exist_ok=True)
            (directory / 'latest.json').write_bytes(local_previous.read_bytes())
            wait_uploaded(tool, [previous_file], args.upload_timeout)
            install_native(tool, directory, previous)
            print('Previously published personal release verified, installed and relaunched.')
            return
        raise ValueError('The cloud already contains this or a newer build; do not overwrite it.')
    if previous and tuple(map(int, version.split('.'))) <= tuple(map(int, previous['version'].split('.'))):
        raise ValueError('Marketing version must also exceed the current cloud version.')
    if not args.resume:
        text = re.sub(r'^MARKETING_VERSION = .*$', f'MARKETING_VERSION = {version}', text, flags=re.M)
        text = re.sub(r'^CURRENT_PROJECT_VERSION = .*$', f'CURRENT_PROJECT_VERSION = {build}', text, flags=re.M)
        config.write_text(text)
        run('git', 'add', 'app/Config/Shared.xcconfig')
        env = {**os.environ, 'GIT_AUTHOR_NAME': 'liuyang', 'GIT_AUTHOR_EMAIL': '40610243@qq.com',
               'GIT_COMMITTER_NAME': 'liuyang', 'GIT_COMMITTER_EMAIL': '40610243@qq.com'}
        run('git', 'commit', '-m', f'Release v{version}', env=env)
    commit = output('git', 'rev-parse', 'HEAD')
    directory = ROOT / f'app/DerivedData/PersonalReleases/v{version}-{build}'
    directory.mkdir(parents=True, exist_ok=True)
    swift_tests(directory, commit)
    # Reuse immutable successful packages during --resume, otherwise rebuild cleanly.
    stamp_file = directory / 'stamp.txt'
    if not stamp_file.exists():
        stamp_file.write_text(datetime.now().astimezone().strftime('%Y-%m-%d_%H-%M-%S%z'))
    stamp = stamp_file.read_text().strip()
    packages = []
    for architecture, script, verifier, minimum in [
        ('x86_64', 'build-ventura.sh', 'verify-ventura-app.py', '13.0'),
        ('arm64', 'build-apple-silicon.sh', 'verify-apple-silicon-app.py', '14.0'),
    ]:
        filename = f'Remarc-{version}-{build}-{stamp}-{architecture}.zip'
        archive = directory / filename
        if not args.resume or not archive.exists():
            env = {**os.environ, 'REMARC_BUILD_CONFIGURATION': 'Release'}
            run('bash', ROOT / 'scripts' / script, env=env)
            app = ROOT / 'app/DerivedData/Build/Products/Release/Remarc.app'
            run('python3', ROOT / 'scripts' / verifier, app)
            run('python3', ROOT / 'scripts/sign-app.py', app, '--channel', 'production', '--verify-only')
            run('node', ROOT / 'scripts/smoke-mcp-images.mjs', app / 'Contents/Resources/remarc-mcp.js', 'production')
            temporary = archive.with_suffix('.building.zip')
            run('ditto', '-c', '-k', '--keepParent', app, temporary)
            temporary.replace(archive)
        packages.append(dict(architecture=architecture, minimumOS=minimum, filename=filename,
                             sha256=sha256(archive), size=archive.stat().st_size))
    manifest = dict(format=1, version=version, build=build, sourceCommit=commit,
                    publishedAt=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), packages=packages)
    unsigned = directory / 'manifest.json'
    unsigned.write_text(json.dumps(manifest, sort_keys=True))
    signed = directory / 'latest.json'
    run(tool, 'sign', unsigned, signed, keychain)
    # Validate provenance from the actual ZIPs, including packages reused after a failure.
    import tempfile
    for package in packages:
        with tempfile.TemporaryDirectory(prefix='remarc-release-verify-') as unpacked:
            run('ditto', '-x', '-k', directory / package['filename'], unpacked)
            run(tool, 'verify-app', signed, Path(unpacked) / 'Remarc.app', package['architecture'])
            verifier = 'verify-ventura-app.py' if package['architecture'] == 'x86_64' else 'verify-apple-silicon-app.py'
            run('python3', ROOT / 'scripts' / verifier, Path(unpacked) / 'Remarc.app')
    targets = []
    for package in packages:
        target = cloud / package['filename']
        if target.exists():
            if sha256(target) != package['sha256']:
                raise ValueError('An existing cloud package has different contents; never overwrite it.')
        else:
            # Only final immutable names appear in the committed description.
            temp = cloud / ('.upload-' + package['filename'])
            run('ditto', directory / package['filename'], temp)
            temp.replace(target)
        targets.append(target)
    wait_uploaded(tool, targets, args.upload_timeout)
    run(tool, 'commit', signed, previous_file, expected)
    wait_uploaded(tool, [previous_file], args.upload_timeout)
    if previous_file.read_bytes() != signed.read_bytes():
        raise ValueError('Another publisher changed the update description. No packages were removed.')
    run(tool, 'cleanup', signed, previous_file, *([p['filename'] for p in previous['packages']] if previous else []))
    (directory / 'SHA256SUMS').write_text(''.join(f"{p['sha256']}  {p['filename']}\n" for p in packages))
    install_native(tool, directory, manifest)
    print(f'Published Remarc {version} ({build}) to {cloud}. Both packages are retained at {directory}.')
    print('The version commit is local. Push main when you want to sync source; pushing does not build on GitHub.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, TimeoutError, subprocess.CalledProcessError) as error:
        print(f'Personal release stopped: {error}', file=sys.stderr)
        raise SystemExit(1)
