#!/usr/bin/env python3
"""Fail if tracked files (and, optionally, a built app) carry personal data.

Checks: home-folder paths, e-mail addresses, Bilibili cookies or tokens with real-looking
values, API keys, Shadowsocks links, public IPv4 addresses, private names given with --deny,
and (with --authors) commit authors that are not GitHub noreply addresses.
Run before publishing:  python3 scripts/privacy_check.py --authors --app dist/release/满屏.app
"""
import argparse
import ipaddress
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
TEXT = {'.swift', '.py', '.md', '.json', '.txt', '.c', '.h', '.sh', '.proto', '.plist', '.yml', '.yaml', '.resolved', ''}
# Values that only appear in tests and fixtures.
FIXTURE = re.compile(r'fixture|private|example|redacted|placeholder|test|sample|dummy|xxx', re.I)
PATTERNS = {
    'home path': re.compile(r'/Users/(?!Shared/)[A-Za-z0-9._-]+/'),
    'e-mail': re.compile(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b'),
    # KEY=value (cookies, query strings) and "KEY": "value" (JSON, plists exported as JSON).
    'cookie/token': re.compile(r'\b(SESSDATA|bili_jct|DedeUserID|DedeUserID__ckMd5|sid|buvid3|access_key|access_token'
                               r'|refresh_token|accessToken|refreshToken|id_token|idToken|api_?[Kk]ey|apiKey|password)'
                               r'(?:=|"\s*:\s*")([^;&\s"\']{6,})'),
    'API key': re.compile(r'\b(sk-(?:ant-)?[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{30,})'),
    'Shadowsocks link': re.compile(r'\bss://[A-Za-z0-9+/=_-]{8,}'),
    'IPv4': re.compile(r'\b(?:\d{1,3}\.){3}\d{1,3}\b'),
}
# Addresses that are fine to publish: documentation ranges and well-known public resolvers.
# Upstream license texts copied unchanged: their copyright holders' addresses must stay.
VERBATIM = ('ThirdPartyNotices/Libraries/',)
ALLOWED_EMAILS = re.compile(r'noreply|@example\.|\.invalid$|@users\.noreply\.github\.com|licensing@|@fsf\.org|@gnu\.org'
                            r'|^(user|pass|password|name)@', re.I)


def looks_secret(key, value):
    """Real cookies, tokens and keys are long and mix letters with digits; test values and
    interpolations ("access-1", "secret-server-error", "\\(token)") are not."""
    if FIXTURE.search(value) or '\\(' in value or value.startswith(('$', '<', '%@', '{')):
        return False
    if key == 'DedeUserID':
        return re.fullmatch(r'\d{6,}', value) is not None  # account ids are plain numbers
    shortest = 6 if key == 'password' else 12
    return len(value) >= shortest and re.search(r'\d', value) is not None and re.search(r'[A-Za-z]', value) is not None


# Cookie records such as {"name": "SESSDATA", "domain": …, "value": "…"}, in any key order and
# across lines; matched on the whole text, one flat object at a time.
COOKIE_RECORD = re.compile(r'\{[^{}]*\}')
COOKIE_NAME = re.compile(r'"name"\s*:\s*"(SESSDATA|bili_jct|DedeUserID|DedeUserID__ckMd5|sid|buvid3)"')
COOKIE_VALUE = re.compile(r'"value"\s*:\s*"([^"]*)"')


def scan_text(name, text, deny):
    problems = []
    for record in COOKIE_RECORD.finditer(text):
        cookie, value = COOKIE_NAME.search(record.group(0)), COOKIE_VALUE.search(record.group(0))
        if cookie and value and looks_secret(cookie.group(1), value.group(1)):
            line_number = text.count('\n', 0, record.start()) + 1
            problems.append(f'{name}:{line_number}: cookie record: {cookie.group(1)}={value.group(1)[:40]}')
    for line_number, line in enumerate(text.splitlines(), 1):
        for label, pattern in PATTERNS.items():
            for match in pattern.finditer(line):
                value = match.group(0)
                if label == 'e-mail' and (ALLOWED_EMAILS.search(value) or name.startswith(VERBATIM)):
                    continue
                if label == 'cookie/token' and not looks_secret(match.group(1), match.group(2)):
                    continue
                if label == 'IPv4':
                    try:
                        address = ipaddress.ip_address(value)
                    except ValueError:
                        continue  # version numbers like 1.2.3.400
                    if address.is_private or address.is_loopback or address.is_unspecified or address.is_reserved \
                            or address.is_link_local or str(address).startswith(('192.0.2.', '198.51.100.', '203.0.113.')):
                        continue
                    # Dotted versions ("luajit 5.1.2.1", "libfoo.5.1.2.1.dylib") are not addresses.
                    before = line[max(0, match.start() - 12):match.start()]
                    if re.search(r'(version|[A-Za-z]-|\d\.|[A-Za-z]\.)$', before, re.I) or 'luajit' in line.lower():
                        continue
                problems.append(f'{name}:{line_number}: {label}: {value[:80]}')
        for word in deny:
            if word and word.lower() in line.lower():
                problems.append(f'{name}:{line_number}: denied word: {word}')
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--deny', action='append', default=[], help='private word that must not appear (repeatable)')
    parser.add_argument('--authors', action='store_true', help='also require noreply commit authors')
    parser.add_argument('--app', type=pathlib.Path, help='also scan text resources and binaries of a built app')
    args = parser.parse_args()
    files = subprocess.run(['git', 'ls-files'], cwd=ROOT, capture_output=True, text=True, check=True).stdout.split('\n')
    problems = []
    for name in files:
        path = ROOT / name
        if not name or not path.is_file() or (path.suffix not in TEXT and path.name not in ('LICENSE',)):
            continue
        if name == 'scripts/privacy_check.py':
            continue
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            continue
        problems += scan_text(name, text, args.deny)
    if args.app:
        executable = None
        if (args.app / 'Contents/Info.plist').is_file():
            import plistlib
            info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
            executable = args.app / 'Contents/MacOS' / info.get('CFBundleExecutable', '')
        if executable is None or not executable.is_file():
            print(f'not an app bundle with Info.plist and its main executable: {args.app}')
            return 2
        for path in args.app.rglob('*'):
            if not path.is_file():
                continue
            data = path.read_bytes()
            text = data.decode('utf-8', 'ignore') if path.suffix in TEXT else \
                '\n'.join(s.decode('ascii', 'ignore') for s in re.findall(rb'[\x20-\x7e]{8,}', data))
            problems += [p for p in scan_text(str(path.relative_to(args.app.parent)), text, args.deny)
                         if any(label in p for label in ('home path', 'cookie', 'API key', 'Shadowsocks', 'denied'))]
    if args.authors:
        for author in subprocess.run(['git', 'log', '--format=%ae%n%ce'], cwd=ROOT, capture_output=True, text=True,
                                     check=True).stdout.split():
            if 'users.noreply.github.com' not in author:
                problems.append(f'git author/committer is not a noreply address: {author}')
                break
    for problem in problems:
        print(problem)
    print(f'privacy check: {len(problems)} finding(s)')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
