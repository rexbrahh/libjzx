import {spawnSync} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

function rmrf(p) {
  fs.rmSync(p, {recursive: true, force: true});
}

function ensureDir(p) {
  fs.mkdirSync(p, {recursive: true});
}

function hasDoxygen() {
  const res = spawnSync('doxygen', ['--version'], {stdio: 'ignore'});
  return res.status === 0;
}

function hasZig() {
  const res = spawnSync('zig', ['version'], {stdio: 'ignore'});
  return res.status === 0;
}

function runOrThrow(cmd, args, opts) {
  const res = spawnSync(cmd, args, {stdio: 'inherit', ...opts});
  if (res.status !== 0) {
    throw new Error(`Command failed: ${cmd} ${args.join(' ')}`);
  }
}

const docsRoot = process.cwd();
const repoRoot = path.resolve(docsRoot, '..');

const doxygenOut = path.join(docsRoot, 'static', 'api', 'doxygen');
const zigOut = path.join(docsRoot, 'static', 'api', 'zig');

rmrf(doxygenOut);
rmrf(zigOut);
ensureDir(doxygenOut);
ensureDir(zigOut);

// --- C API (Doxygen) ---------------------------------------------------------

if (!hasDoxygen()) {
  // eslint-disable-next-line no-console
  console.warn('[gen:api] doxygen not found; skipping C API reference generation.');
} else {
  runOrThrow('doxygen', ['Doxyfile'], {cwd: docsRoot});
}

// --- Zig wrapper API (Zig compiler HTML docs) --------------------------------

if (!hasZig()) {
  throw new Error('[gen:api] zig not found; cannot generate Zig API reference.');
}

runOrThrow(
  'zig',
  [
    'test',
    path.join(repoRoot, 'zig', 'jzx', 'lib.zig'),
    '--test-no-exec',
    '-I',
    path.join(repoRoot, 'include'),
    `-femit-docs=${zigOut}`,
    '-fno-emit-bin',
  ],
  {cwd: docsRoot},
);
