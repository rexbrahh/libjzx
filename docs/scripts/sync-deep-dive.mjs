import fs from 'node:fs';
import path from 'node:path';

const isCheckMode = process.argv.includes('--check');

const docsRoot = process.cwd();
const repoRoot = path.resolve(docsRoot, '..');

const mappings = [
  {
    docPath: path.join(docsRoot, 'docs', 'deep-dive', 'include-jzx-jzx-h.md'),
    codeFence: '```c title="include/jzx/jzx.h" showLineNumbers',
    sourcePath: path.join(repoRoot, 'include', 'jzx', 'jzx.h'),
  },
  {
    docPath: path.join(docsRoot, 'docs', 'deep-dive', 'src-jzx-internal-h.md'),
    codeFence: '```c title="src/jzx_internal.h" showLineNumbers',
    sourcePath: path.join(repoRoot, 'src', 'jzx_internal.h'),
  },
  {
    docPath: path.join(docsRoot, 'docs', 'deep-dive', 'zig-jzx-lib-zig.md'),
    codeFence: '```zig title="zig/jzx/lib.zig" showLineNumbers',
    sourcePath: path.join(repoRoot, 'zig', 'jzx', 'lib.zig'),
  },
  {
    docPath: path.join(docsRoot, 'docs', 'deep-dive', 'src-jzx-xev-zig.md'),
    codeFence: '```zig title="src/jzx_xev.zig" showLineNumbers',
    sourcePath: path.join(repoRoot, 'src', 'jzx_xev.zig'),
  },
  {
    docPath: path.join(docsRoot, 'docs', 'deep-dive', 'src-jzx-runtime-c.md'),
    codeFence: '```c title="src/jzx_runtime.c" showLineNumbers',
    sourcePath: path.join(repoRoot, 'src', 'jzx_runtime.c'),
  },
  {
    docPath: path.join(docsRoot, 'docs', 'deep-dive', 'zig-tests-basic-zig.md'),
    codeFence: '```zig title="zig/tests/basic.zig" showLineNumbers',
    sourcePath: path.join(repoRoot, 'zig', 'tests', 'basic.zig'),
  },
];

function normalizeNewlines(input) {
  return input.replace(/\r\n/g, '\n');
}

function updateDoc(docText, codeFenceLine, sourceText) {
  const normalizedDoc = normalizeNewlines(docText);
  const normalizedSource = normalizeNewlines(sourceText).replace(/\n$/, '');

  const start = normalizedDoc.indexOf(codeFenceLine);
  if (start === -1) {
    throw new Error(`Could not find code fence: ${codeFenceLine}`);
  }

  const fenceBodyStart = normalizedDoc.indexOf('\n', start);
  if (fenceBodyStart === -1) {
    throw new Error(`Malformed code fence (no newline): ${codeFenceLine}`);
  }

  const endFence = '\n```';
  const fenceEnd = normalizedDoc.indexOf(endFence, fenceBodyStart + 1);
  if (fenceEnd === -1) {
    throw new Error(`Could not find closing fence for: ${codeFenceLine}`);
  }

  const before = normalizedDoc.slice(0, fenceBodyStart + 1);
  const after = normalizedDoc.slice(fenceEnd);
  return `${before}${normalizedSource}${after}`;
}

let changed = 0;

for (const { docPath, codeFence, sourcePath } of mappings) {
  const docText = fs.readFileSync(docPath, 'utf8');
  const sourceText = fs.readFileSync(sourcePath, 'utf8');
  const updated = updateDoc(docText, codeFence, sourceText);

  if (normalizeNewlines(updated) !== normalizeNewlines(docText)) {
    changed += 1;
    if (isCheckMode) {
      // eslint-disable-next-line no-console
      console.error(`Out of date: ${path.relative(repoRoot, docPath)} (run: npm run sync:deep-dive)`);
    } else {
      fs.writeFileSync(docPath, updated);
      // eslint-disable-next-line no-console
      console.log(`Updated: ${path.relative(repoRoot, docPath)}`);
    }
  }
}

if (isCheckMode && changed > 0) {
  process.exitCode = 1;
}
