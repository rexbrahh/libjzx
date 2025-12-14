import fs from 'node:fs';
import path from 'node:path';

const isCheckMode = process.argv.includes('--check');

// Run from <repoRoot>/docs.
const docsRoot = process.cwd();
const repoRoot = path.resolve(docsRoot, '..');

const deepDiveRoot = path.join(docsRoot, 'docs', 'deep-dive');

const coreFiles = [
  'build.zig.zon',
  'build.zig',
  'include/jzx/jzx.h',
  'src/jzx_internal.h',
  'src/jzx_runtime.c',
  'src/jzx_xev.zig',
  'zig/jzx/lib.zig',
  'zig/tests/basic.zig',
  'tools/stress.zig',
  'examples/c/loop.c',
  'examples/c/supervisor.c',
  'examples/zig/ping.zig',
  'examples/zig/typed_actor.zig',
  'examples/zig/supervisor.zig',
  'examples/zig/echo_server.zig',
];

function normalizeNewlines(input) {
  return input.replace(/\r\n/g, '\n');
}

function readFileNormalized(absPath) {
  const raw = fs.readFileSync(absPath, 'utf8');
  const normalized = normalizeNewlines(raw);
  return normalized.endsWith('\n') ? normalized.slice(0, -1) : normalized;
}

function listMarkdownFiles(dir) {
  /** @type {string[]} */
  const out = [];

  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...listMarkdownFiles(fullPath));
      continue;
    }
    if (fullPath.endsWith('.md') || fullPath.endsWith('.mdx')) {
      out.push(fullPath);
    }
  }

  return out;
}

function addCoverage(set, startLine, endLine) {
  for (let i = startLine; i <= endLine; i += 1) {
    set.add(i);
  }
}

function extractSnippetRangesFromDoc(docPath) {
  const raw = readFileNormalized(docPath);
  const lines = raw.split('\n');

  /** @type {Array<{relPath: string, isAll: boolean, startLine: number, endLine: number}>} */
  const ranges = [];

  for (let i = 0; i < lines.length; i += 1) {
    const m = lines[i].match(/<!--\s*snippet:\s*([^>]+?)\s*-->/);
    if (!m) continue;

    const spec = m[1].trim();
    const hashIdx = spec.indexOf('#');
    const relPath = (hashIdx === -1 ? spec : spec.slice(0, hashIdx)).trim();
    const selector = hashIdx === -1 ? '' : spec.slice(hashIdx + 1).trim();
    const isAll = !selector || selector === 'all';

    // Find next code fence.
    let fenceStart = i + 1;
    while (fenceStart < lines.length && !lines[fenceStart].startsWith('```')) {
      fenceStart += 1;
    }
    if (fenceStart >= lines.length) {
      throw new Error(`No code fence after snippet directive in ${docPath}:${i + 1}`);
    }

    const header = lines[fenceStart];
    const showMatch = header.match(/showLineNumbers(?:=(\d+))?/);
    if (!showMatch || !showMatch[1]) {
      throw new Error(`Missing showLineNumbers=... after snippet directive in ${docPath}:${fenceStart + 1}`);
    }
    const startLine = parseInt(showMatch[1], 10);

    let fenceEnd = fenceStart + 1;
    while (fenceEnd < lines.length && !lines[fenceEnd].startsWith('```')) {
      fenceEnd += 1;
    }
    if (fenceEnd >= lines.length) {
      throw new Error(`Unclosed code fence after snippet directive in ${docPath}:${i + 1}`);
    }

    const snippetLineCount = fenceEnd - fenceStart - 1;
    const endLine = startLine + snippetLineCount - 1;

    ranges.push({ relPath, isAll, startLine, endLine });
    i = fenceEnd;
  }

  return ranges;
}

/** @type {Map<string, Array<{isAll: boolean, startLine: number, endLine: number}>>} */
const perSourceRanges = new Map();

for (const docPath of listMarkdownFiles(deepDiveRoot)) {
  for (const range of extractSnippetRangesFromDoc(docPath)) {
    const list = perSourceRanges.get(range.relPath) ?? [];
    list.push(range);
    perSourceRanges.set(range.relPath, list);
  }
}

function computeNonEmptyLineSet(sourceLines) {
  /** @type {Set<number>} */
  const interesting = new Set();
  for (let i = 0; i < sourceLines.length; i += 1) {
    if (sourceLines[i].trim() !== '') {
      interesting.add(i + 1);
    }
  }
  return interesting;
}

function uncoveredRanges(totalLineCount, interesting, covered) {
  /** @type {Array<[number, number]>} */
  const ranges = [];

  let i = 1;
  while (i <= totalLineCount) {
    if (!interesting.has(i) || covered.has(i)) {
      i += 1;
      continue;
    }
    const start = i;
    while (i <= totalLineCount && interesting.has(i) && !covered.has(i)) {
      i += 1;
    }
    ranges.push([start, i - 1]);
  }

  return ranges;
}

/** @type {Array<{relPath: string, covered: number, total: number, pct: number, uncovered: Array<[number, number]>}>} */
const results = [];

for (const relPath of coreFiles) {
  const abs = path.join(repoRoot, relPath);
  const sourceLines = readFileNormalized(abs).split('\n');
  const interesting = computeNonEmptyLineSet(sourceLines);

  /** @type {Set<number>} */
  const covered = new Set();
  for (const r of perSourceRanges.get(relPath) ?? []) {
    if (r.isAll) continue;
    addCoverage(covered, r.startLine, r.endLine);
  }

  let coveredCount = 0;
  for (const l of interesting) {
    if (covered.has(l)) coveredCount += 1;
  }

  const total = interesting.size;
  const pct = total === 0 ? 100 : Math.round((coveredCount / total) * 100);

  results.push({
    relPath,
    covered: coveredCount,
    total,
    pct,
    uncovered: uncoveredRanges(sourceLines.length, interesting, covered),
  });
}

results.sort((a, b) => a.pct - b.pct);

let anyMissing = false;
for (const r of results) {
  const ok = r.covered === r.total;
  if (!ok) anyMissing = true;
  // eslint-disable-next-line no-console
  console.log(`${ok ? 'OK' : 'MISS'} ${r.relPath}: ${r.covered}/${r.total} (${r.pct}%)`);
  if (!ok) {
    const formatted = r.uncovered
      .map(([a, b]) => (a === b ? `L${a}` : `L${a}-L${b}`))
      .join(', ');
    // eslint-disable-next-line no-console
    console.log(`  uncovered: ${formatted}`);
  }
}

if (isCheckMode && anyMissing) {
  process.exitCode = 1;
}
