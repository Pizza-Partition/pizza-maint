#!/usr/bin/env python3
"""Fetch pinned source archives with curl, then let Zig verify package identities."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def dependencies(lock):
    pattern = r'\.(\w+)\s*=\s*\.\{\s*\.url\s*=\s*"([^"]+)"\s*,\s*\.hash\s*=\s*"([^"]+)"'
    found = re.findall(pattern, lock)
    if not found:
        raise ValueError('No content-locked source dependencies found')
    return found


def archives(lock):
    return [(name, url, expected) for name, url, expected in dependencies(lock) if url.startswith('https://')]


def fetch_archive(zig, directory, package_directory, name, url, expected):
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
    # Zig 0.17 global-only fetch preserves an extra archive root when it
    # recompresses sources without a manifest. Fetch into the build's local
    # package directory so the original verified root is used directly.
    # --save-exact updates only the disposable manifest, never the real lock.
    subprocess.check_output([zig, 'fetch', f'--save-exact={name}', '--pkg-dir', str(package_directory), source], cwd=directory, text=True)
    actual = next(identity for dependency, _, identity in dependencies((directory / 'build.zig.zon').read_text()) if dependency == name)
    if actual != expected:
        raise ValueError(f'{name}: source package differs from the locked hash')


def main():
    zig = os.environ.get('ZIG', 'zig')
    lock = Path('build.zig.zon').read_text()
    package_directory = Path(os.environ.get('ZIG_LOCAL_PKG_DIR', 'zig-pkg')).resolve()
    with tempfile.TemporaryDirectory(prefix='pizza-source-deps-') as temporary:
        directory = Path(temporary)
        (directory / 'build.zig').write_text('')
        (directory / 'build.zig.zon').write_text(lock)
        for name, url, expected in archives(lock):
            print(f'Fetching locked source: {name}', flush=True)
            fetch_archive(zig, directory, package_directory, name, url, expected)
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
