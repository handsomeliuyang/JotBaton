#!/usr/bin/env python3
"""Regression tests for release version and package provenance checks."""
import importlib.util
import os
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


prepare = load('prepare-fork-release')
verify = load('verify-fork-release')


class ReleaseTests(unittest.TestCase):
    def test_new_release_and_exact_resume(self):
        prepare.validate_version('1.2.4', '23', '1.2.5', '24', 'Feature commit')
        prepare.validate_version('1.2.5', '24', '1.2.5', '24', 'Release v1.2.5')

    def test_refuses_reused_version_build_and_unrelated_resume(self):
        for version, build, subject in [
            ('1.2.4', '24', 'Feature'), ('1.2.5', '23', 'Feature'),
            ('1.2.3', '24', 'Feature'), ('1.2.4', '23', 'Feature'),
        ]:
            with self.subTest(version=version, build=build), self.assertRaises(ValueError):
                prepare.validate_version('1.2.4', '23', version, build, subject)

    def test_refuses_malformed_inputs(self):
        for version, build in [('01.2.5', '24'), ('1.2.5\nfoo', '24'), ('1.2', '24'),
                               ('1.2.5', '0'), ('1.2.5', '024'), ('1.2.5', '24\n')]:
            with self.subTest(version=version, build=build), self.assertRaises(ValueError):
                prepare.validate_version('1.2.4', '23', version, build, '')

    def test_rejects_package_from_wrong_commit_version_or_update_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Remarc.app'
            (app / 'Contents').mkdir(parents=True)
            info = {'CFBundleIdentifier': 'com.metepolat.Remarc', 'RemarcChannel': 'production',
                    'CFBundleShortVersionString': '1.2.5', 'CFBundleVersion': '24',
                    'RemarcSourceCommit': 'a' * 40, 'RemarcManualUpdates': True, 'RemarcCloudUpdates': True}
            env = {'VERSION': '1.2.5', 'BUILD_NUMBER': '24', 'SOURCE_SHA': 'a' * 40}
            plist = app / 'Contents/Info.plist'
            with patch.dict(os.environ, env), patch.object(verify, 'run'):
                plist.write_bytes(plistlib.dumps(info))
                verify.verify_app(app, 'verifier.py')
                for key, wrong in [('CFBundleIdentifier', 'com.metepolat.Remarc.dev'),
                                   ('RemarcChannel', 'development'), ('CFBundleShortVersionString', '1.2.4'),
                                   ('CFBundleVersion', '23'), ('RemarcSourceCommit', 'b' * 40),
                                   ('RemarcManualUpdates', False), ('RemarcCloudUpdates', False)]:
                    plist.write_bytes(plistlib.dumps({**info, key: wrong}))
                    with self.subTest(key=key), self.assertRaises(ValueError):
                        verify.verify_app(app, 'verifier.py')


if __name__ == '__main__':
    unittest.main()
