#!/usr/bin/env python3
"""Preview or explicitly dispatch Remarc's GitHub-only production release."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = 'handsomeliuyang/JotBaton'
VERSION_PATTERN = r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
RELEASE_SUBJECT = r'(?:Release v|chore\([^)]+\): release v)' + VERSION_PATTERN
MARKER = '<!-- remarc-release: '


def run(*args, cwd=ROOT, input=None):
    result = subprocess.run(args, cwd=cwd, input=input, text=True, capture_output=True,
                            env={**os.environ, 'GIT_TERMINAL_PROMPT': '0'}, timeout=120)
    if result.returncode:
        # Never relay credential-bearing subprocess errors to release logs.
        raise ValueError(f'{args[0]} {args[1]} failed (exit {result.returncode})')
    return result.stdout.strip()


def version_tuple(version):
    if not re.fullmatch(VERSION_PATTERN, version):
        raise ValueError('Version must be X.Y.Z without leading zeroes')
    return tuple(map(int, version.split('.')))


def read_version(root=ROOT):
    config = (root / 'app/Config/Shared.xcconfig').read_text()
    versions = re.findall(r'^MARKETING_VERSION = (\S+)$', config, re.M)
    builds = re.findall(r'^CURRENT_PROJECT_VERSION = ([1-9][0-9]*)$', config, re.M)
    if len(versions) != 1 or len(builds) != 1:
        raise ValueError('Expected exactly one version and build field')
    version_tuple(versions[0])
    return versions[0], builds[0]


def next_version(current, requested):
    parts = list(version_tuple(current))
    if requested in ('major', 'minor', 'patch'):
        index = ('major', 'minor', 'patch').index(requested)
        parts[index] += 1
        parts[index + 1:] = [0] * (2 - index)
        return '.'.join(map(str, parts))
    version_tuple(requested)
    return requested


def releases(*, public_fallback=False):
    try:
        pages = json.loads(run('gh', 'api', '--paginate', '--slurp',
                               f'repos/{REPOSITORY}/releases?per_page=100'))
        return [release for page in pages for release in page]
    except (ValueError, OSError, subprocess.TimeoutExpired):
        if not public_fallback:
            raise ValueError('GitHub authentication/API failed; restore gh access before publishing') from None
    result = []
    for page in range(1, 101):
        request = urllib.request.Request(
            f'https://api.github.com/repos/{REPOSITORY}/releases?per_page=100&page={page}',
            headers={'Accept': 'application/vnd.github+json', 'User-Agent': 'Remarc-release'})
        with urllib.request.urlopen(request, timeout=30) as response:
            items = json.load(response)
        result.extend(items)
        if len(items) < 100:
            return result
    raise ValueError('Release pagination limit exceeded')


def published_base(items, source, root=ROOT):
    candidates = [item for item in items if not item['draft'] and not item['prerelease']
                  and re.fullmatch('v' + VERSION_PATTERN, item['tag_name'])]
    candidates.sort(key=lambda item: version_tuple(item['tag_name'][1:]), reverse=True)
    if not candidates:
        raise ValueError('No published stable release found; establish a baseline explicitly')
    latest = candidates[0]['tag_name']
    # Never silently omit a newer stable release from a divergent source line.
    run('git', 'merge-base', '--is-ancestor', latest, source, cwd=root)
    return latest


def validate_available(items, version, build):
    for item in items:
        tag = item['tag_name']
        if tag == 'v' + version:
            raise ValueError(f'Release {tag} already exists; inspect it instead of overwriting it')
        if not item['draft'] and not item['prerelease'] and re.fullmatch('v' + VERSION_PATTERN, tag):
            if version_tuple(version) <= version_tuple(tag[1:]):
                raise ValueError('Version must exceed every published stable release')
        # Published build provenance is appended by this repository's workflow.
        advertised = re.search(r'Version: [0-9.]+ \(([1-9][0-9]*)\)', item.get('body') or '')
        if advertised and int(build) <= int(advertised[1]):
            raise ValueError('Build must exceed every advertised release build')


def commit_notes(base, source, root=ROOT):
    raw = run('git', 'log', '--reverse', '--no-merges', '--format=%H%x00%B%x00',
              f'{base}..{source}', cwd=root)
    fields = raw.split('\0')
    groups = {name: {} for name in ('重大变更', '新增', '修复', '性能', '其他变更')}
    for index in range(0, len(fields) - 1, 2):
        sha, message = fields[index].strip(), fields[index + 1].strip()
        if not message:
            continue
        subject = message.splitlines()[0]
        if re.fullmatch(RELEASE_SUBJECT, subject):
            continue
        match = re.match(r'([a-z]+)(?:\([^)]+\))?(!)?:\s*(.+)', subject, re.I)
        kind, breaking, title = match.groups() if match else ('', None, subject)
        note = re.search(r'^Release-Note:\s*(.+)$', message, re.M | re.I)
        title = note[1] if note else title
        group = {'feat': '新增', 'fix': '修复', 'perf': '性能'}.get(kind.lower(), '其他变更')
        if breaking or re.search(r'^BREAKING[ -]CHANGE:', message, re.M):
            group = '重大变更'
        # Escape commit text so it cannot inject Markdown headings/HTML/links.
        title = re.sub(r'([\\`*_{}\[\]<>()#!|])', r'\\\1', title)
        groups[group].setdefault(title, []).append(sha)
    sections = []
    for group, entries in groups.items():
        if entries:
            bullets = []
            for title, shas in entries.items():
                links = ', '.join(f'[{sha[:7]}](https://github.com/{REPOSITORY}/commit/{sha})' for sha in shas)
                bullets.append(f'- {title} ({links})')
            sections.append(f'### {group}\n\n' + '\n'.join(bullets))
    if not sections:
        raise ValueError('No unreleased changes found')
    return '\n\n'.join(sections)


def generate_notes(base, source, version, root=ROOT):
    return commit_notes(base, source, root) + f'\n\n[完整变更](https://github.com/{REPOSITORY}/compare/{base}...v{version})'


def validate_notes(notes):
    notes = notes.strip()
    if not notes or len(notes.encode('utf-8')) > 32000:
        raise ValueError('Release notes must contain 1–32000 UTF-8 bytes')
    if re.search(r'^#{1,2}\s', notes, re.M) or MARKER in notes:
        raise ValueError('Notes may use ### sections but cannot contain release headings or metadata')
    if not re.search(r'^-\s+\S', notes, re.M):
        raise ValueError('Release notes must include at least one Markdown bullet')
    return notes


def changelog_entry(changelog, version):
    match = re.search(r'^## ' + re.escape(version) + r' - \d{4}-\d{2}-\d{2}\n(.*?)(?=^## |\Z)',
                      changelog, re.M | re.S)
    if not match:
        raise ValueError('Missing changelog entry for the release version')
    notes, separator, metadata = match[1].strip().rpartition('\n\n' + MARKER)
    if not separator or not metadata.endswith(' -->'):
        raise ValueError('Missing release provenance in changelog')
    return validate_notes(notes), json.loads(metadata[:-4])


def prepend_changelog(changelog, version, notes, metadata):
    if re.search(r'^## ' + re.escape(version) + r'(?:\s|$)', changelog, re.M):
        raise ValueError('Changelog already contains this version')
    date = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    entry = f'## {version} - {date}\n\n{validate_notes(notes)}\n\n{MARKER}{json.dumps(metadata, sort_keys=True)} -->\n\n'
    first = re.search(r'^## ', changelog, re.M)
    if first:
        return changelog[:first.start()] + entry + changelog[first.start():]
    return changelog.rstrip() + '\n\n' + entry


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('version', nargs='?', default='patch', help='patch (default), minor, major or X.Y.Z')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--publish', action='store_true', help='explicitly dispatch the production Release workflow')
    mode.add_argument('--dry-run', action='store_true', help='preview only (also the default)')
    parser.add_argument('--notes-file', type=Path, help='reviewed Markdown notes, e.g. a Chinese summary of commits')
    parser.add_argument('--source-sha', help='refuse if HEAD differs from the reviewed full source SHA')
    args = parser.parse_args()
    current, current_build = read_version()
    version = next_version(current, args.version)
    if version_tuple(version) <= version_tuple(current):
        raise ValueError('Marketing version must increase')
    source = run('git', 'rev-parse', 'HEAD')
    if args.source_sha and args.source_sha != source:
        raise ValueError('Source changed since preview; review the current commits before publishing')
    items = releases(public_fallback=not args.publish)
    advertised_builds = [int(m[1]) for item in items if (m := re.search(
        r'Version: [0-9.]+ \(([1-9][0-9]*)\)', item.get('body') or ''))]
    build = str(max([int(current_build)] + advertised_builds) + 1)
    validate_available(items, version, build)
    base = published_base(items, source)
    generated = generate_notes(base, source, version)
    notes = validate_notes(args.notes_file.read_text() if args.notes_file else generated)
    dirty = bool(run('git', 'status', '--porcelain'))
    print(f'当前版本: {current} ({current_build})\n目标版本: {version} ({build})\n'
          f'提交范围: {base}..{source}\n工作区: {"有未提交更改（预览不包含这些改动）" if dirty else "干净"}\n\n{notes}', flush=True)
    if not args.publish:
        print('\n仅预览；使用 --publish 才会触发 GitHub Release。')
        return
    if dirty or run('git', 'branch', '--show-current') != 'main':
        raise ValueError('Publish requires a clean main checkout')
    if run('git', 'remote', 'get-url', 'origin') not in (
            f'git@github.com:{REPOSITORY}.git', f'https://github.com/{REPOSITORY}.git'):
        raise ValueError('origin must point to this repository')
    run('git', 'fetch', 'origin', 'main', '--tags')
    if run('git', 'rev-parse', 'origin/main') != source:
        raise ValueError('Push accepted commits to origin/main before publishing')
    if run('git', 'tag', '--list', 'v' + version):
        raise ValueError('Target tag already exists; inspect the failed release instead')
    active = json.loads(run('gh', 'run', 'list', '-R', REPOSITORY, '--workflow', 'release.yml',
                            '--limit', '100', '--json', 'status'))
    if any(item['status'] != 'completed' for item in active):
        raise ValueError('A Release run is active; finish or recover it before starting another')
    # gh accepts structured JSON on stdin; multiline notes never pass through a shell.
    run('gh', 'workflow', 'run', 'release.yml', '-R', REPOSITORY, '--ref', 'main', '--json',
        input=json.dumps({'version': version, 'build_number': build,
                          'release_notes': notes, 'source_sha': source}))
    print(f'\n已提交发布请求（尚未发布成功）。源码: {source}\n'
          f'https://github.com/{REPOSITORY}/actions/workflows/release.yml')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        print(f'Release stopped: {error}', file=sys.stderr)
        sys.exit(1)
