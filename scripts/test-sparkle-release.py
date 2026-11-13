#!/usr/bin/env python3
"""Update feed regression tests; macOS also verifies real Sparkle/CryptoKit signatures."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('sparkle_release', ROOT / 'scripts/sparkle-release.py')
updates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updates)
SIGNER = next((p for p in [ROOT / 'build/sparkle-tools/bin/sign_update',
                          ROOT / 'app/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update',
                          ROOT / 'app/RemarcPackage/.build/artifacts/sparkle/Sparkle/bin/sign_update'] if p.is_file()), None)


class FeedTests(unittest.TestCase):
    def test_each_feed_pins_native_package_version_build_os_and_escaped_notes(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            for arch, (filename, minimum) in updates.PACKAGES.items():
                (output / filename).write_bytes(b'installer')
                path = updates.write_feed(output, arch, '1.2.37', '56', 'Fix <unsafe> & notes', 'signature')
                item = ET.fromstring(path.read_bytes()).find('./channel/item')
                self.assertEqual(item.findtext(updates.tag('version')), '56')
                self.assertEqual(item.findtext(updates.tag('shortVersionString')), '1.2.37')
                self.assertEqual(item.findtext(updates.tag('minimumSystemVersion')), minimum)
                self.assertEqual(item.findtext('description'), 'Fix <unsafe> & notes')
                self.assertEqual(item.find('enclosure').get('url'), 'https://github.com/handsomeliuyang/Remarc/releases/download/v1.2.37/' + filename)
                with self.assertRaises(ValueError):
                    updates.write_feed(output, arch, '1.2.37', '56', '', 'signature')

    def test_no_local_production_update_signing(self):
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'false'}), self.assertRaises(ValueError):
            updates.generate(Path('/unused'), '1.2.37', '56', 'notes')

    def test_unsigned_malformed_and_truncated_feeds_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'feed.xml'
            for data in [b'<rss/>', b'<rss/><!-- sparkle-signatures:\n',
                         b'<rss/><!-- sparkle-signatures:\nlength: 99\nedSignature: abc\n-->',
                         b'<rss/><!-- sparkle-signatures:\nlength: 6\nlength: 6\nedSignature: abc\n-->']:
                path.write_bytes(data)
                with self.subTest(data=data), self.assertRaises((ValueError, KeyError)):
                    updates.feed_content(path)

    @unittest.skipUnless(platform.system() == 'Darwin' and SIGNER is not None, 'Requires macOS and verified Sparkle tools')
    def test_real_signatures_reject_tampered_packages_feeds_and_wrong_pinned_key(self):
        # Disposable test key; never reads or changes the production update key.
        generated = subprocess.check_output(['swift', '-e', '''import CryptoKit; import Foundation
let key = Curve25519.Signing.PrivateKey()
let object = ["seed": key.rawRepresentation.base64EncodedString(), "public": key.publicKey.rawRepresentation.base64EncodedString()]
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: object))'''])
        key = json.loads(generated)
        config = {'public_ed_key': key['public']}
        with tempfile.TemporaryDirectory() as directory, patch.object(updates, 'configuration', return_value=config):
            output = Path(directory)
            for arch, (filename, _) in updates.PACKAGES.items():
                (output / filename).write_bytes(('fixture ' + arch).encode())
                signature = updates.sign(SIGNER, output / filename, key['seed'].encode())
                feed = updates.write_feed(output, arch, '1.2.37', '56', 'notes', signature)
                updates.sign(SIGNER, feed, key['seed'].encode(), feed=True)
            updates.verify(output, '1.2.37', '56')
            with self.assertRaises(ValueError):
                updates.verify(output, '1.2.38', '57')
            package = output / updates.PACKAGES['arm64'][0]
            original = package.read_bytes()
            package.write_bytes(b'x' * len(original))
            with self.assertRaises(subprocess.CalledProcessError):
                updates.verify(output, '1.2.37', '56')
            package.write_bytes(original)
            config['public_ed_key'] = base64.b64encode(bytes(32)).decode()
            with self.assertRaises(subprocess.CalledProcessError):
                updates.verify(output, '1.2.37', '56')
            config['public_ed_key'] = key['public']
            feed = output / 'appcast-arm64.xml'
            feed.write_bytes(feed.read_bytes().replace(b'<title>Remarc ', b'<title>remarc ', 1))
            with self.assertRaises(subprocess.CalledProcessError):
                updates.verify(output, '1.2.37', '56')


if __name__ == '__main__':
    unittest.main()
