#!/usr/bin/env python3
"""Exercise legacy app migration, channel isolation and rollback without touching installed apps."""
import contextlib
import io
import plistlib
import runpy
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class InstallMigrationTests(unittest.TestCase):
    def exercise(self, *, fail_launch=False, wrong_channel=False):
        with tempfile.TemporaryDirectory() as directory:
            sandbox = Path(directory)
            applications = sandbox / 'Applications'
            home = sandbox / 'home'
            source = sandbox / 'download/JotBaton Dev.app'
            legacy = applications / 'Remarc Dev.app'
            production = applications / 'Remarc.app'
            data = home / 'Library/Application Support/Remarc Dev'
            for app in (source, legacy, production):
                (app / 'Contents').mkdir(parents=True)
                info = {'CFBundleIdentifier': 'com.metepolat.Remarc.dev', 'CFBundleExecutable': 'RemarcDev'}
                if app == production or (app == legacy and wrong_channel):
                    info['CFBundleIdentifier'] = 'com.metepolat.Remarc'
                (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
                (app / 'marker').write_text('new' if app == source else 'old')
            data.mkdir(parents=True)
            (data / 'comments.json').write_text('existing development data')
            calls = []

            def sandbox_path(*parts):
                if parts == ('/Applications',):
                    return applications
                return Path(*parts)

            def run(command, **kwargs):
                calls.append(command)
                if command[0] == 'ditto':
                    shutil.copytree(command[1], command[2])
                if 'relaunch-app.py' in command[1] and fail_launch:
                    raise subprocess.CalledProcessError(1, command)
                return subprocess.CompletedProcess(command, 0)

            with patch('pathlib.Path', side_effect=sandbox_path) as path_type, \
                 patch('sys.argv', ['install-app.py', str(source), '--channel', 'development', '--skip-diagnostics']), \
                 patch('subprocess.run', side_effect=run), \
                 patch('subprocess.check_output', return_value='arm64'), \
                 patch('platform.machine', return_value='arm64'), patch('time.sleep'), \
                 contextlib.redirect_stdout(io.StringIO()):
                path_type.home.return_value = home
                if wrong_channel:
                    with self.assertRaisesRegex(ValueError, 'different channel'):
                        runpy.run_path(str(ROOT / 'scripts/install-app.py'), run_name='__main__')
                elif fail_launch:
                    with self.assertRaises(subprocess.CalledProcessError):
                        runpy.run_path(str(ROOT / 'scripts/install-app.py'), run_name='__main__')
                else:
                    runpy.run_path(str(ROOT / 'scripts/install-app.py'), run_name='__main__')
            current = applications / 'JotBaton Dev.app'
            self.assertEqual((production / 'marker').read_text(), 'old')
            self.assertEqual((data / 'comments.json').read_text(), 'existing development data')
            if wrong_channel or fail_launch:
                self.assertTrue(legacy.is_dir())
                self.assertFalse(current.exists())
                if wrong_channel:
                    self.assertFalse(any(c[0] == 'pkill' for c in calls))
            else:
                self.assertEqual((current / 'marker').read_text(), 'new')
                self.assertFalse(legacy.exists())
                backups = list((home / 'Library/Application Support/Remarc Install Backups').iterdir())
                self.assertEqual((backups[0] / 'Remarc Dev.app/marker').read_text(), 'old')
                self.assertEqual((backups[0] / 'user-data/comments.json').read_text(), 'existing development data')
                self.assertFalse((home / 'Library/Application Support/JotBaton Dev').exists())

    def test_migrates_only_matching_channel_and_keeps_existing_data(self):
        self.exercise()

    def test_failed_launch_restores_legacy_location(self):
        self.exercise(fail_launch=True)

    def test_other_channel_at_legacy_location_is_rejected_before_quitting(self):
        self.exercise(wrong_channel=True)


if __name__ == '__main__':
    unittest.main()
