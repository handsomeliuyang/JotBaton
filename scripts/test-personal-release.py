#!/usr/bin/env python3
"""Host eligibility and iCloud publication guard regressions; never build or publish."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('personal_release', Path(__file__).with_name('publish-icloud-update.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class PersonalReleaseTests(unittest.TestCase):
    def test_intel_host_rejected_before_toolchain_or_signing_access(self):
        with patch.object(release.platform, 'system', return_value='Darwin'), patch.object(release.platform, 'machine', return_value='x86_64'), patch.object(release, 'output') as output:
            with self.assertRaises(ValueError):
                release.require_host()
            output.assert_not_called()

    def test_capable_apple_silicon_host_is_not_model_specific(self):
        with patch.object(release.platform, 'system', return_value='Darwin'), patch.object(release.platform, 'machine', return_value='arm64'), patch.object(release, 'output', side_effect=['Xcode 26.2\nBuild version 17C52', 'Apple Swift version 6.2.3']):
            release.require_host()

    def test_old_xcode_or_selected_swift_is_rejected(self):
        for results in [['Xcode 15.2'], ['Xcode 26.2', 'Apple Swift version 5.8.1']]:
            with self.subTest(results=results), patch.object(release.platform, 'system', return_value='Darwin'), patch.object(release.platform, 'machine', return_value='arm64'), patch.object(release, 'output', side_effect=results):
                with self.assertRaises(ValueError):
                    release.require_host()

    def test_waits_for_each_package_upload(self):
        paths = [Path('/private/one.zip'), Path('/private/two.zip')]
        with patch.object(release, 'output', side_effect=['uploaded', 'uploading', 'uploaded']) as output, patch.object(release.time, 'sleep'):
            release.wait_uploaded('tool', paths, 30)
            self.assertEqual(output.call_count, 3)
            self.assertEqual(output.call_args.args[-1], paths[1])

    def test_local_folder_cannot_be_mistaken_for_confirmed_icloud(self):
        with patch.object(release, 'output', return_value='not-cloud'), self.assertRaises(ValueError):
            release.wait_uploaded('tool', [Path('/tmp/package.zip')], 30)

    def test_unconfirmed_upload_times_out(self):
        with patch.object(release, 'output', return_value='uploading'), patch.object(release.time, 'monotonic', side_effect=[0, 31]), self.assertRaises(TimeoutError):
            release.wait_uploaded('tool', [Path('/private/package.zip')], 30)

    def test_resume_only_reuses_full_suites_for_exact_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / 'tests.commit'
            marker.write_text('a' * 40)
            with patch.object(release, 'run') as run:
                release.swift_tests(Path(directory), 'a' * 40)
                run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
