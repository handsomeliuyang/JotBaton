#!/usr/bin/env python3
"""Local Release entry points must stop before resolution, compilation or signing."""
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class BuildPolicyTests(unittest.TestCase):
    def test_local_release_builders_stop_before_building(self):
        env = {**os.environ, 'GITHUB_ACTIONS': 'false', 'REMARC_BUILD_CONFIGURATION': 'Release'}
        for script in ['build-apple-silicon.sh', 'build-ventura.sh']:
            with self.subTest(script=script):
                result = subprocess.run(['bash', str(ROOT / 'scripts' / script)], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn('only in GitHub Actions', result.stderr)

    def test_local_production_packaging_and_signing_are_rejected(self):
        env = {**os.environ, 'GITHUB_ACTIONS': 'false'}
        identity = json.loads((ROOT / 'signing/identities.json').read_text())['production']
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Remarc.app'
            (app / 'Contents').mkdir(parents=True)
            info = {'CFBundleIdentifier': identity['bundle_id'], 'CFBundleExecutable': 'Remarc',
                    'CFBundleURLTypes': [{'CFBundleURLSchemes': [identity['url_scheme']]}]}
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            for script in ['prepare-app.py', 'sign-app.py']:
                with self.subTest(script=script):
                    result = subprocess.run(['python3', str(ROOT / 'scripts' / script), str(app), '--channel', 'production'],
                                            env=env, capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('GitHub Actions', result.stderr)
                    self.assertEqual(plistlib.loads((app / 'Contents/Info.plist').read_bytes()), info)


if __name__ == '__main__':
    unittest.main()
