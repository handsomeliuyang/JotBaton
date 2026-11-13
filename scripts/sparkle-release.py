#!/usr/bin/env python3
"""Sign and verify architecture-specific Sparkle feeds for one immutable GitHub Release."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
NAMESPACE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NAMESPACE)
PACKAGES = {'arm64': ('Remarc-Apple-Silicon-arm64.dmg', '14.0'),
            'x86_64': ('Remarc-Ventura-x86_64.zip', '13.0')}


def tag(name):
    return '{' + NAMESPACE + '}' + name


def configuration():
    config = json.loads((ROOT / 'signing/updates.json').read_text())
    if len(base64.b64decode(config['public_ed_key'], validate=True)) != 32:
        raise ValueError('Invalid pinned public update key')
    return config


def sign(signer, path, key, *, feed=False):
    # Never put a private key in arguments, a file, errors or subprocess output.
    result = subprocess.run([str(signer), '--ed-key-file', '-', '-p', str(path)],
                            input=key, capture_output=True)
    if result.returncode:
        raise RuntimeError('Sparkle could not sign the update asset')
    if feed:
        return None
    signature = result.stdout.decode().strip()
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('Sparkle returned an invalid signature')
    return signature


def verify_signature(public, path, signature):
    subprocess.run(['swift', str(ROOT / 'scripts/verify-update-signature.swift'), public, str(path), signature], check=True)


def feed_content(path):
    data = path.read_bytes()
    prefix = b'<!-- sparkle-signatures:\n'
    start = data.rfind(prefix)
    end = data.find(b'-->', start + len(prefix)) if start >= 0 else -1
    if start < 0 or end < 0 or data[end + 3:].strip():
        raise ValueError('Missing or malformed Sparkle feed signature')
    fields = {}
    for line in data[start + len(prefix):end].decode().splitlines():
        name, _, value = line.partition(':')
        if name in fields:
            raise ValueError('Duplicate Sparkle signature field')
        fields[name] = value.strip()
    content = data[:start]
    if int(fields.get('length', '-1')) != len(content):
        raise ValueError('Sparkle feed content length mismatch')
    return content, fields['edSignature']


def write_feed(directory, arch, version, build, notes, signature):
    filename, minimum_os = PACKAGES[arch]
    package = directory / filename
    rss = ET.Element('rss', version='2.0')
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'Remarc ' + arch
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = 'Remarc ' + version
    ET.SubElement(item, tag('version')).text = build
    ET.SubElement(item, tag('shortVersionString')).text = version
    ET.SubElement(item, tag('minimumSystemVersion')).text = minimum_os
    ET.SubElement(item, 'description', {tag('format'): 'markdown'}).text = notes
    ET.SubElement(item, 'enclosure', {
        'url': f'https://github.com/handsomeliuyang/Remarc/releases/download/v{version}/{filename}',
        'length': str(package.stat().st_size), 'type': 'application/octet-stream',
        tag('edSignature'): signature,
    })
    output = directory / f'appcast-{arch}.xml'
    if output.exists():
        raise ValueError('Never overwrite an existing release feed')
    ET.indent(rss)
    output.write_bytes(ET.tostring(rss, encoding='utf-8', xml_declaration=True) + b'\n')
    return output


def verify(directory, version, build):
    public = configuration()['public_ed_key']
    for arch, (filename, minimum_os) in PACKAGES.items():
        feed = directory / f'appcast-{arch}.xml'
        content, signature = feed_content(feed)
        with tempfile.TemporaryDirectory(prefix='remarc-feed-verify-') as temp:
            unsigned = Path(temp) / 'content'
            unsigned.write_bytes(content)
            verify_signature(public, unsigned, signature)
        rss = ET.fromstring(content)
        items = rss.findall('./channel/item')
        if len(items) != 1:
            raise ValueError('Expected exactly one release per architecture feed')
        item = items[0]
        expected = {tag('version'): build, tag('shortVersionString'): version, tag('minimumSystemVersion'): minimum_os}
        if any(item.findtext(key) != value for key, value in expected.items()):
            raise ValueError('Update feed version, build or OS floor does not match the release')
        enclosures = item.findall('enclosure')
        if len(enclosures) != 1:
            raise ValueError('Expected one native update package')
        enclosure = enclosures[0]
        package = directory / filename
        url = f'https://github.com/handsomeliuyang/Remarc/releases/download/v{version}/{filename}'
        if enclosure.get('url') != url or enclosure.get('length') != str(package.stat().st_size):
            raise ValueError('Update feed package URL or size does not match the release')
        verify_signature(public, package, enclosure.attrib[tag('edSignature')])
    print('Verified both signed update feeds and native packages against the pinned public key')


def signer_tool():
    cache = ROOT / 'app/DerivedData/PackageCache'
    subprocess.run(['python3', str(ROOT / 'scripts/cache-binary-artifacts.py'), str(cache)], check=True)
    archive = cache / 'artifacts/https___github_com_sparkle_project_Sparkle_releases_download_2_9_5_Sparkle_for_Swift_Package_Manager_zip'
    output = ROOT / 'build/sparkle-tools'
    if output.exists():
        raise ValueError('Use a clean release workspace for signing tools')
    subprocess.run(['ditto', '-x', '-k', str(archive), str(output)], check=True)
    return output / 'bin/sign_update'


def generate(directory, version, build, notes):
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        raise ValueError('Production update signing runs only in GitHub Actions')
    key = os.environ['REMARC_UPDATE_EDDSA_KEY'].strip().encode()
    signer = signer_tool()
    for arch, (filename, _) in PACKAGES.items():
        signature = sign(signer, directory / filename, key)
        # Fail before publishing if the Actions secret differs from the app's pinned key.
        verify_signature(configuration()['public_ed_key'], directory / filename, signature)
        feed = write_feed(directory, arch, version, build, notes, signature)
        sign(signer, feed, key, feed=True)
    verify(directory, version, build)
    files = sorted(path for path in directory.iterdir() if path.name != 'SHA256SUMS')
    (directory / 'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in files))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    if args.verify_only:
        verify(args.directory, os.environ['VERSION'], os.environ['BUILD_NUMBER'])
    else:
        generate(args.directory, os.environ['VERSION'], os.environ['BUILD_NUMBER'], os.environ['NOTES'])
