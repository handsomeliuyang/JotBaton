#!/usr/bin/env python3
"""Validate a new fork release or resume its exact version commit."""
import os
import re
import uuid
from pathlib import Path

from release import (changelog_entry, generate_notes, prepend_changelog, published_base,
                     read_version, releases, run, validate_available, validate_notes)


def validate_version(current_version, current_build, version, build, subject):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("Version must be X.Y.Z without leading zeroes")
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("Build number must be a positive integer")
    if version == current_version and build == current_build:
        if subject not in (f"Release v{version}", f"chore({version}): release v{version}"):
            raise ValueError("Only the exact release version commit may be resumed")
        return
    if tuple(map(int, version.split('.'))) <= tuple(map(int, current_version.split('.'))):
        raise ValueError("Marketing version must increase")
    if int(build) <= int(current_build):
        raise ValueError("Build number must increase")


def main():
    version, build = os.environ['VERSION'], os.environ['BUILD_NUMBER']
    supplied_notes = os.environ.get('NOTES', '').strip()
    path = Path('app/Config/Shared.xcconfig')
    text = path.read_text()
    current_version, current_build = read_version(Path.cwd())
    subject = run('git', 'log', '-1', '--format=%s', cwd=Path.cwd())
    validate_version(current_version, current_build, version, build, subject)
    head = run('git', 'rev-parse', 'HEAD', cwd=Path.cwd())
    expected = os.environ['EXPECTED_SOURCE_SHA']
    if not re.fullmatch(r'[0-9a-f]{40}', expected):
        raise ValueError('Expected source must be a full commit SHA')
    resume = (version, build) == (current_version, current_build)
    changelog_path = Path('CHANGELOG.md')
    changelog = changelog_path.read_text()
    items = releases()
    validate_available(items, version, build)
    if resume:
        parent = run('git', 'rev-parse', 'HEAD^', cwd=Path.cwd())
        if expected not in (head, parent):
            raise ValueError('Only the exact approved release commit may be resumed')
        if subject == f'Release v{version}':
            # Old version commits did not contain a changelog entry. Do not
            # mutate their source/provenance during a workflow recovery.
            notes = validate_notes(supplied_notes)
            base = published_base(items, parent, Path.cwd())
        else:
            notes, metadata = changelog_entry(changelog, version)
            if metadata['build'] != build or metadata['source_sha'] != parent:
                raise ValueError('Release changelog provenance does not match the version commit')
            base = published_base(items, parent, Path.cwd())
            if metadata['base_tag'] != base:
                raise ValueError('Published baseline changed; choose a new version/build')
            if supplied_notes and validate_notes(supplied_notes) != notes:
                raise ValueError('Cannot change release notes when resuming an exact version commit')
    else:
        if head != expected:
            raise ValueError('main changed after release approval; preview the new source before dispatching')
        if run('git', 'tag', '--list', 'v' + version, cwd=Path.cwd()):
            raise ValueError('Target tag already exists; inspect the failed release instead')
        base = published_base(items, head, Path.cwd())
        generated = generate_notes(base, head, version, Path.cwd())
        notes = validate_notes(supplied_notes or generated)
        changelog_path.write_text(prepend_changelog(changelog, version, notes, {
            'build': build, 'source_sha': head, 'base_tag': base,
        }))
    text = re.sub(r'^MARKETING_VERSION = .*$', f'MARKETING_VERSION = {version}', text, flags=re.M)
    text = re.sub(r'^CURRENT_PROJECT_VERSION = .*$', f'CURRENT_PROJECT_VERSION = {build}', text, flags=re.M)
    path.write_text(text)
    output = Path('build')
    output.mkdir(exist_ok=True)
    (output / 'release-commit-message.txt').write_text(
        f'chore({version}): release v{version}\n\nBuild: {build}\nPrevious release: {base}\n\n{notes}\n')
    if os.environ.get('GITHUB_OUTPUT'):
        delimiter = 'REMARC_NOTES_' + uuid.uuid4().hex
        with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
            stream.write(f'release_notes<<{delimiter}\n{notes}\n{delimiter}\n')


if __name__ == '__main__':
    main()
