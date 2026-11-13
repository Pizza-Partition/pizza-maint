// Canonical source: pizza-maint/tools/install-zig.mjs. Sync through sync-shared.mjs.
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export async function installZig({
  lockPath = 'config/toolchain.json',
  directory,
  platform = process.platform,
  arch = process.arch,
  fetchArchive = globalThis.fetch,
  pathFile = process.env.GITHUB_PATH,
} = {}) {
  const lock = JSON.parse(await fs.readFile(lockPath, 'utf8'));
  const system = { linux: 'linux', win32: 'windows', darwin: 'macos' }[platform];
  const cpu = { x64: 'x86_64', arm64: 'aarch64' }[arch];
  const source = lock[`${cpu}-${system}`];
  if (
    !source ||
    !/^\d+\.\d+\.\d+(?:[-.a-zA-Z0-9]*)$/.test(lock.version) ||
    !/^[a-f0-9]{64}$/.test(source.sha256)
  )
    throw Error('Invalid or unsupported locked Zig platform');
  const response = await fetchArchive(source.url, { signal: AbortSignal.timeout(120000) });
  if (!response.ok) throw Error(`Zig download: ${response.status}`);
  const bytes = Buffer.from(await response.arrayBuffer());
  if (createHash('sha256').update(bytes).digest('hex') !== source.sha256)
    throw Error('Zig archive SHA-256 mismatch');
  const destination =
    directory ??
    (await fs.mkdtemp(path.join(process.env.RUNNER_TEMP ?? os.tmpdir(), 'pizza-zig-')));
  await fs.mkdir(destination, { recursive: true });
  const archive = path.join(destination, platform === 'win32' ? 'zig.zip' : 'zig.tar.xz');
  await fs.writeFile(archive, bytes);
  if (platform === 'win32') {
    execFileSync(
      'powershell',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Expand-Archive -LiteralPath $env:PIZZA_ZIG_ARCHIVE -DestinationPath $env:PIZZA_ZIG_DESTINATION',
      ],
      {
        env: { ...process.env, PIZZA_ZIG_ARCHIVE: archive, PIZZA_ZIG_DESTINATION: destination },
        stdio: 'inherit',
      },
    );
  } else execFileSync('tar', ['-xJf', archive, '-C', destination]);
  const installed = path.join(destination, `zig-${cpu}-${system}-${lock.version}`);
  const executable = path.join(installed, platform === 'win32' ? 'zig.exe' : 'zig');
  if (execFileSync(executable, ['version'], { encoding: 'utf8' }).trim() !== lock.version)
    throw Error('Zig version mismatch');
  if (pathFile) await fs.appendFile(pathFile, `${installed}\n`);
  return installed;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length > 3) throw Error('Usage: node tools/install-zig.mjs [toolchain.json]');
  console.log(await installZig({ lockPath: process.argv[2] ?? 'config/toolchain.json' }));
}
