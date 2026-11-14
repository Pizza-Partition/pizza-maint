import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { installZig } from './install-zig.mjs';

async function fixture(t, reported = '0.17.1') {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'pizza-zig-test-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const name = 'zig-x86_64-linux-0.17.1';
  await fs.mkdir(path.join(root, name));
  await fs.writeFile(path.join(root, name, 'zig'), `#!/bin/sh\nprintf '%s\\n' '${reported}'\n`, {
    mode: 0o755,
  });
  execFileSync('tar', ['-cJf', path.join(root, 'fixture.tar.xz'), '-C', root, name]);
  const bytes = await fs.readFile(path.join(root, 'fixture.tar.xz'));
  const lockPath = path.join(root, 'lock.json');
  const lock = {
    version: '0.17.1',
    'x86_64-linux': {
      url: 'https://ziglang.org/fixture',
      sha256: createHash('sha256').update(bytes).digest('hex'),
    },
  };
  await fs.writeFile(lockPath, JSON.stringify(lock));
  const pathFile = path.join(root, 'github-path');
  return {
    root,
    lockPath,
    pathFile,
    lock,
    options: {
      lockPath,
      pathFile,
      directory: path.join(root, 'installed'),
      platform: 'linux',
      arch: 'x64',
      fetchArchive: async () => new Response(bytes),
    },
  };
}

test(
  'verified archive installs the exact locked version and publishes its path',
  { skip: process.platform !== 'linux' },
  async (t) => {
    const f = await fixture(t);
    const installed = await installZig(f.options);
    assert.equal(await fs.readFile(f.pathFile, 'utf8'), `${installed}\n`);
  },
);
test(
  'tampered archive is rejected before extraction or PATH publication',
  { skip: process.platform !== 'linux' },
  async (t) => {
    const f = await fixture(t);
    await assert.rejects(
      installZig({ ...f.options, fetchArchive: async () => new Response('tampered') }),
      /SHA-256 mismatch/,
    );
    await assert.rejects(fs.stat(f.options.directory), { code: 'ENOENT' });
    await assert.rejects(fs.stat(f.pathFile), { code: 'ENOENT' });
  },
);
test(
  'wrong executable version is rejected before PATH publication',
  { skip: process.platform !== 'linux' },
  async (t) => {
    const f = await fixture(t, '0.17.0');
    await assert.rejects(installZig(f.options), /version mismatch/);
    await assert.rejects(fs.stat(f.pathFile), { code: 'ENOENT' });
  },
);
test(
  'failed download does not publish or extract a toolchain',
  { skip: process.platform !== 'linux' },
  async (t) => {
    const f = await fixture(t);
    await assert.rejects(
      installZig({ ...f.options, fetchArchive: async () => new Response('', { status: 503 }) }),
      /503/,
    );
    await assert.rejects(fs.stat(f.options.directory), { code: 'ENOENT' });
  },
);
