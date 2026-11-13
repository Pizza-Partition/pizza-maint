#!/usr/bin/env python3
"""Fetch pinned source archives with curl, then let Zig verify package identities."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def archives(lock):
    pattern = r'\.(\w+)\s*=\s*\.\{\s*\.url\s*=\s*"([^"]+)"\s*,\s*\.hash\s*=\s*"([^"]+)"'
    found = re.findall(pattern, lock)
    if not found:
        raise ValueError('No content-locked source dependencies found')
    return [(name, url, expected) for name, url, expected in found if url.startswith('https://')]


def fetch_archive(zig, directory, name, url, expected):
    extension = '.zip' if url.endswith('.zip') else '.tar.xz' if url.endswith('.tar.xz') else '.tar.gz'
    archive = directory / (name + extension)
    try:
        subprocess.run(['curl', '--fail', '--location', '--silent', '--show-error', '--retry', '3', '--retry-all-errors', '--connect-timeout', '20', '--max-time', '180', '--output', str(archive), url], check=True)
        source = str(archive)
    except subprocess.CalledProcessError:
        # Some upstreams reject curl while accepting Zig's native client.
        # Both transports must produce the exact same locked package identity.
        print(f'{name}: curl transport failed; trying the Zig HTTPS client', flush=True)
        source = url
    actual = subprocess.check_output([zig, 'fetch', source], text=True).strip()
    if actual != expected:
        raise ValueError(f'{name}: source package differs from the locked hash')


def main():
    zig = os.environ.get('ZIG', 'zig')
    with tempfile.TemporaryDirectory(prefix='pizza-source-deps-') as temporary:
        for name, url, expected in archives(Path('build.zig.zon').read_text()):
            print(f'Fetching locked source: {name}', flush=True)
            fetch_archive(zig, Path(temporary), name, url, expected)
    # Resolve Git and transitive dependencies with the same content-locked graph.
    for attempt in range(3):
        result = subprocess.run([zig, 'build', '--fetch'])
        if result.returncode == 0:
            return
        if attempt == 2:
            raise SystemExit(result.returncode)
        time.sleep(10)


if __name__ == '__main__':
    main()
