#!/usr/bin/env python3
"""Exercise commit ranges, release provenance and dispatch guards without publishing."""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import release

spec = importlib.util.spec_from_file_location('prepare_release', Path(__file__).with_name('prepare-fork-release.py'))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


def published(version='1.2.4', build='23', **changes):
    return {'tag_name': 'v' + version, 'draft': False, 'prerelease': False,
            'body': f'Version: {version} ({build})', **changes}


class VersionAndAvailabilityTests(unittest.TestCase):
    def test_explicit_and_incremented_versions(self):
        for request, expected in [('patch', '1.2.5'), ('minor', '1.3.0'), ('major', '2.0.0'), ('3.4.5', '3.4.5')]:
            self.assertEqual(release.next_version('1.2.4', request), expected)
        for invalid in ('01.2.5', 'v1.2.5', '1.2', '1.2.5\n', '1.2.5-rc1'):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                release.next_version('1.2.4', invalid)

    def test_drafts_block_reuse_but_are_not_published_baselines(self):
        with self.assertRaisesRegex(ValueError, 'already exists'):
            release.validate_available([published('1.2.5', '24', draft=True)], '1.2.5', '25')
        for version, build in [('1.2.3', '24'), ('1.2.5', '23')]:
            with self.subTest(version=version, build=build), self.assertRaises(ValueError):
                release.validate_available([published()], version, build)

    def test_untrusted_notes_cannot_inject_changelog_entries(self):
        for notes in ('', 'A paragraph', '## 9.9.9\n- injected', '- ok\n' + release.MARKER + '{} -->', '- ' + '字' * 11000):
            with self.subTest(notes=notes[:30]), self.assertRaises(ValueError):
                release.validate_notes(notes)


class CommandTests(unittest.TestCase):
    source = 'a' * 40

    def invoke(self, arguments, *, dirty=False, synced=True, active=False):
        calls = []

        def command(*args, **kwargs):
            calls.append((args, kwargs))
            if args[:3] == ('git', 'rev-parse', 'HEAD'):
                return self.source
            if args[:3] == ('git', 'status', '--porcelain'):
                return ' M file.swift' if dirty else ''
            if args[:3] == ('git', 'branch', '--show-current'):
                return 'main'
            if args[:3] == ('git', 'remote', 'get-url'):
                return f'git@github.com:{release.REPOSITORY}.git'
            if args[:3] == ('git', 'rev-parse', 'origin/main'):
                return self.source if synced else 'b' * 40
            if args[:3] == ('gh', 'run', 'list'):
                return json.dumps([{'status': 'in_progress'}] if active else [])
            if args[:2] in (('git', 'fetch'), ('git', 'tag')) or args[:3] == ('gh', 'workflow', 'run'):
                return ''
            raise AssertionError(args)

        with patch('sys.argv', ['release.py'] + arguments), patch('sys.stdout', new_callable=io.StringIO), \
                patch.object(release, 'run', side_effect=command), \
                patch.object(release, 'read_version', return_value=('1.2.4', '23')), \
                patch.object(release, 'releases', return_value=[published()]), \
                patch.object(release, 'published_base', return_value='v1.2.4'), \
                patch.object(release, 'generate_notes', return_value='- 自动日志'):
            release.main()
        return calls

    def test_default_and_dry_run_never_dispatch_even_with_dirty_workspace(self):
        for arguments in ([], ['minor', '--dry-run']):
            calls = self.invoke(arguments, dirty=True)
            self.assertFalse(any(args[0] == 'gh' for args, _ in calls))
            self.assertFalse(any(args[:2] == ('git', 'fetch') for args, _ in calls))

    def test_publish_passes_exact_source_notes_and_version_as_structured_json(self):
        calls = self.invoke(['minor', '--publish', '--source-sha', self.source])
        dispatches = [(args, kwargs) for args, kwargs in calls if args[:3] == ('gh', 'workflow', 'run')]
        self.assertEqual(len(dispatches), 1)
        self.assertEqual(json.loads(dispatches[0][1]['input']), {
            'version': '1.3.0', 'build_number': '24', 'release_notes': '- 自动日志', 'source_sha': self.source,
        })

    def test_dirty_unsynced_active_or_changed_source_cannot_dispatch(self):
        for options in ({'dirty': True}, {'synced': False}, {'active': True}):
            with self.subTest(options=options), self.assertRaises(ValueError):
                self.invoke(['--publish'], **options)
        with self.assertRaisesRegex(ValueError, 'Source changed'):
            self.invoke(['--publish', '--source-sha', 'b' * 40])


class GitReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='remarc-release-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'liuyang')
        self.git('config', 'user.email', '40610243@qq.com')
        self.git('config', 'commit.gpgsign', 'false')
        config = self.root / 'app/Config'
        config.mkdir(parents=True)
        (config / 'Shared.xcconfig').write_text('MARKETING_VERSION = 1.2.4\nCURRENT_PROJECT_VERSION = 23\n')
        (self.root / 'CHANGELOG.md').write_text('# Changelog\n\nHistory.\n\n## 1.2.4 - 2026-11-01\n\n- Before\n')
        self.git('add', '.')
        self.commit('Release v1.2.4')
        self.git('tag', 'v1.2.4')
        self.commit('feat: new feature\n\nRelease-Note: 新增快捷记录')
        self.source = self.git('rev-parse', 'HEAD')

    def git(self, *args):
        return release.run('git', *args, cwd=self.root)

    def commit(self, message):
        self.git('commit', '--allow-empty', '-m', message)

    def prepare(self, **env):
        previous = Path.cwd()
        try:
            os.chdir(self.root)
            with patch.dict(os.environ, {'VERSION': '1.2.5', 'BUILD_NUMBER': '24', 'NOTES': '',
                                        'EXPECTED_SOURCE_SHA': self.source,
                                        'GITHUB_OUTPUT': str(self.root / 'outputs'), **env}), \
                    patch.object(prepare, 'releases', return_value=[published()]):
                prepare.main()
        finally:
            os.chdir(previous)

    def test_grouping_legacy_commits_breaking_changes_and_release_filter(self):
        self.commit('fix(ui): repair selection')
        self.commit('perf: reduce allocations')
        self.commit('Refactor legacy storage')
        self.commit('feat!: remove old voice API')
        self.commit('chore: tighten persistence\n\nBREAKING CHANGE: older clients cannot write')
        self.commit('Release v1.2.4')
        self.commit('chore(1.2.4): release v1.2.4')
        self.commit('fix: escape [link](javascript:bad) <tag>')
        notes = release.generate_notes('v1.2.4', 'HEAD', '1.2.5', self.root)
        for content in ('### 新增', '### 修复', '### 性能', '### 其他变更', '### 重大变更',
                        '新增快捷记录', 'Refactor legacy storage', '/compare/v1.2.4...v1.2.5', '\\[link\\]'):
            self.assertIn(content, notes)
        self.assertNotIn('Release v1.2.4', notes)
        self.assertNotIn('chore(1.2.4)', notes)
        self.assertNotIn('<tag>', notes)

    def test_duplicate_titles_retain_each_commit_link(self):
        self.commit('fix: duplicate description')
        first = self.git('rev-parse', 'HEAD')
        self.commit('fix: duplicate description')
        second = self.git('rev-parse', 'HEAD')
        notes = release.commit_notes('v1.2.4', 'HEAD', self.root)
        self.assertEqual(notes.count('duplicate description'), 1)
        self.assertIn(first, notes)
        self.assertIn(second, notes)

    def test_empty_range_is_not_a_new_release(self):
        with self.assertRaisesRegex(ValueError, 'No unreleased'):
            release.generate_notes('v1.2.4', 'v1.2.4', '1.2.5', self.root)

    def test_baseline_excludes_drafts_and_rejects_divergence(self):
        items = [published(), published('9.0.0', '99', draft=True), published('8.0.0', '98', prerelease=True)]
        self.assertEqual(release.published_base(items, self.source, self.root), 'v1.2.4')
        self.git('checkout', '--orphan', 'other')
        self.commit('Unrelated source')
        self.git('tag', 'v1.3.0')
        with self.assertRaises(ValueError):
            release.published_base(items + [published('1.3.0', '25')], self.source, self.root)

    def test_prepare_uses_one_notes_value_and_exact_resume_is_immutable(self):
        self.prepare()
        self.assertEqual(release.read_version(self.root), ('1.2.5', '24'))
        changelog = (self.root / 'CHANGELOG.md').read_text()
        notes, metadata = release.changelog_entry(changelog, '1.2.5')
        self.assertEqual(metadata, {'build': '24', 'source_sha': self.source, 'base_tag': 'v1.2.4'})
        self.assertIn(notes, (self.root / 'outputs').read_text())
        message = (self.root / 'build/release-commit-message.txt').read_text()
        self.assertTrue(message.startswith('chore(1.2.5): release v1.2.5\n\nBuild: 24'))
        self.assertIn(notes, message)
        self.assertIn('## 1.2.4 - 2026-11-01', changelog)
        self.git('add', 'app/Config/Shared.xcconfig', 'CHANGELOG.md')
        self.git('commit', '-F', 'build/release-commit-message.txt')
        self.prepare()
        self.assertEqual((self.root / 'CHANGELOG.md').read_text(), changelog)
        self.prepare(EXPECTED_SOURCE_SHA=self.git('rev-parse', 'HEAD'))
        with self.assertRaisesRegex(ValueError, 'Cannot change release notes'):
            self.prepare(NOTES='- Changed after approval')

    def test_source_race_fails_without_modifying_tracked_files(self):
        self.commit('fix: arrived after approval')
        before = (self.root / 'CHANGELOG.md').read_text()
        with self.assertRaisesRegex(ValueError, 'main changed'):
            self.prepare()
        self.assertEqual((self.root / 'CHANGELOG.md').read_text(), before)
        self.assertEqual(release.read_version(self.root), ('1.2.4', '23'))

    def test_legacy_release_commit_can_resume_without_rewriting_history(self):
        (self.root / 'app/Config/Shared.xcconfig').write_text('MARKETING_VERSION = 1.2.5\nCURRENT_PROJECT_VERSION = 24\n')
        self.git('add', 'app/Config/Shared.xcconfig')
        self.commit('Release v1.2.5')
        before = (self.root / 'CHANGELOG.md').read_text()
        self.prepare(NOTES='- Original notes')
        self.assertEqual((self.root / 'CHANGELOG.md').read_text(), before)

    def test_reviewed_chinese_notes_are_preserved_exactly(self):
        supplied = '### 新增\n\n- 支持签名校验后在应用内升级。\n- 增加快捷记录。'
        self.prepare(NOTES=supplied)
        notes, _ = release.changelog_entry((self.root / 'CHANGELOG.md').read_text(), '1.2.5')
        self.assertEqual(notes, supplied)


if __name__ == '__main__':
    unittest.main()
