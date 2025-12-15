import fs from 'node:fs';
import path from 'node:path';

const isCheckMode = process.argv.includes('--check');
const includeVersions =
  process.argv.includes('--include-versions') || process.argv.includes('--all');

const docsRoot = process.cwd();
const repoRoot = path.resolve(docsRoot, '..');

const deepDiveRoots = [path.join(docsRoot, 'docs', 'deep-dive')];
if (includeVersions) {
  const versioned = path.join(docsRoot, 'versioned_docs');
  if (fs.existsSync(versioned)) {
    for (const entry of fs.readdirSync(versioned, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      if (!entry.name.startsWith('version-')) continue;
      const root = path.join(versioned, entry.name, 'deep-dive');
      if (fs.existsSync(root)) deepDiveRoots.push(root);
    }
  }
}

const defaultBranch = process.env.DOCS_DEFAULT_BRANCH ?? 'main';
const githubRepo = process.env.GITHUB_REPOSITORY ?? 'rexbrahh/libjzx';
const githubBaseUrl = `https://github.com/${githubRepo}/blob/${defaultBranch}/`;

function normalizeNewlines(input) {
  return input.replace(/\r\n/g, '\n');
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

/** @type {Map<string, string>} */
const sourceCache = new Map();

function readSource(relPath) {
  const abs = path.join(repoRoot, relPath);
  const cached = sourceCache.get(abs);
  if (cached !== undefined) return cached;
  const text = fs.readFileSync(abs, 'utf8');
  const normalized = normalizeNewlines(text);
  sourceCache.set(abs, normalized);
  return normalized;
}

function countLinesBefore(text, index) {
  return text.slice(0, index).split('\n').length;
}

function extractLines(sourceText, startLine, endLine) {
  const lines = sourceText.split('\n');
  const startIdx = startLine - 1;
  const endIdx = endLine - 1;
  if (startIdx < 0 || endIdx < startIdx || endIdx >= lines.length) {
    throw new Error(`Invalid line range: L${startLine}-L${endLine} (file has ${lines.length} lines)`);
  }
  return {
    startLine,
    snippet: lines.slice(startIdx, endIdx + 1).join('\n'),
  };
}

function escapeRegExp(input) {
  return input.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function extractBetween(sourceText, startNeedle, endNeedle) {
  const lines = sourceText.split('\n');
  const startIdx = lines.findIndex((l) => l.includes(startNeedle));
  if (startIdx === -1) {
    throw new Error(`between: could not find start marker: ${JSON.stringify(startNeedle)}`);
  }
  const endIdx = lines.findIndex((l, idx) => idx > startIdx && l.includes(endNeedle));
  if (endIdx === -1) {
    throw new Error(`between: could not find end marker: ${JSON.stringify(endNeedle)}`);
  }
  return {
    startLine: startIdx + 1,
    snippet: lines.slice(startIdx, endIdx).join('\n'),
  };
}

function extractCFunction(sourceText, name) {
  const re = new RegExp(`\\b${escapeRegExp(name)}\\s*\\(`, 'g');
  let match;
  while ((match = re.exec(sourceText)) !== null) {
    const nameIdx = match.index;
    const sigStart = sourceText.lastIndexOf('\n', nameIdx);
    const sigStartIdx = sigStart === -1 ? 0 : sigStart + 1;

    const openParen = sourceText.indexOf('(', nameIdx);
    if (openParen === -1) continue;

    let parenDepth = 0;
    let i = openParen;
    for (; i < sourceText.length; i += 1) {
      const ch = sourceText[i];
      if (ch === '(') parenDepth += 1;
      else if (ch === ')') {
        parenDepth -= 1;
        if (parenDepth === 0) break;
      }
    }
    if (parenDepth !== 0) continue;
    const closeParen = i;

    // Skip whitespace and comments to find '{'
    let j = closeParen + 1;
    while (j < sourceText.length) {
      const ch = sourceText[j];
      if (/\s/.test(ch)) {
        j += 1;
        continue;
      }
      if (ch === '/' && sourceText[j + 1] === '/') {
        j = sourceText.indexOf('\n', j + 2);
        if (j === -1) return null;
        continue;
      }
      if (ch === '/' && sourceText[j + 1] === '*') {
        const end = sourceText.indexOf('*/', j + 2);
        if (end === -1) return null;
        j = end + 2;
        continue;
      }
      break;
    }
    if (sourceText[j] !== '{') {
      continue;
    }
    const bodyStart = j;

    let braceDepth = 0;
    let inLineComment = false;
    let inBlockComment = false;
    let inSingle = false;
    let inDouble = false;
    let escape = false;

    for (let k = bodyStart; k < sourceText.length; k += 1) {
      const ch = sourceText[k];
      const next = sourceText[k + 1] ?? '';

      if (inLineComment) {
        if (ch === '\n') inLineComment = false;
        continue;
      }
      if (inBlockComment) {
        if (ch === '*' && next === '/') {
          inBlockComment = false;
          k += 1;
        }
        continue;
      }
      if (inSingle) {
        if (escape) {
          escape = false;
        } else if (ch === '\\') {
          escape = true;
        } else if (ch === "'") {
          inSingle = false;
        }
        continue;
      }
      if (inDouble) {
        if (escape) {
          escape = false;
        } else if (ch === '\\') {
          escape = true;
        } else if (ch === '"') {
          inDouble = false;
        }
        continue;
      }

      if (ch === '/' && next === '/') {
        inLineComment = true;
        k += 1;
        continue;
      }
      if (ch === '/' && next === '*') {
        inBlockComment = true;
        k += 1;
        continue;
      }
      if (ch === "'") {
        inSingle = true;
        continue;
      }
      if (ch === '"') {
        inDouble = true;
        continue;
      }

      if (ch === '{') {
        braceDepth += 1;
      } else if (ch === '}') {
        braceDepth -= 1;
        if (braceDepth === 0) {
          const endIdx = k + 1;
          const snippet = sourceText.slice(sigStartIdx, endIdx).replace(/\n$/, '');
          const startLine = countLinesBefore(sourceText, sigStartIdx);
          return { startLine, snippet };
        }
      }
    }
  }
  throw new Error(`func: could not find C function definition for ${name}`);
}

function extractZigBlock(sourceText, startIndex) {
  const sigStart = sourceText.lastIndexOf('\n', startIndex);
  const sigStartIdx = sigStart === -1 ? 0 : sigStart + 1;

  // Find the first "{" after the start index (ignoring strings/comments).
  let inLineComment = false;
  let inBlockComment = false;
  let inSingle = false;
  let inDouble = false;
  let escape = false;
  let braceOpen = -1;

  for (let i = startIndex; i < sourceText.length; i += 1) {
    const ch = sourceText[i];
    const next = sourceText[i + 1] ?? '';

    if (inLineComment) {
      if (ch === '\n') inLineComment = false;
      continue;
    }
    if (inBlockComment) {
      if (ch === '*' && next === '/') {
        inBlockComment = false;
        i += 1;
      }
      continue;
    }
    if (inSingle) {
      if (escape) {
        escape = false;
      } else if (ch === '\\') {
        escape = true;
      } else if (ch === "'") {
        inSingle = false;
      }
      continue;
    }
    if (inDouble) {
      if (escape) {
        escape = false;
      } else if (ch === '\\') {
        escape = true;
      } else if (ch === '"') {
        inDouble = false;
      }
      continue;
    }

    if (ch === '/' && next === '/') {
      inLineComment = true;
      i += 1;
      continue;
    }
    if (ch === '/' && next === '*') {
      inBlockComment = true;
      i += 1;
      continue;
    }
    if (ch === "'") {
      inSingle = true;
      continue;
    }
    if (ch === '"') {
      inDouble = true;
      continue;
    }

    if (ch === '{') {
      braceOpen = i;
      break;
    }
  }

  if (braceOpen === -1) {
    throw new Error('zig block: could not find opening brace');
  }

  let braceDepth = 0;
  inLineComment = false;
  inBlockComment = false;
  inSingle = false;
  inDouble = false;
  escape = false;

  for (let i = braceOpen; i < sourceText.length; i += 1) {
    const ch = sourceText[i];
    const next = sourceText[i + 1] ?? '';

    if (inLineComment) {
      if (ch === '\n') inLineComment = false;
      continue;
    }
    if (inBlockComment) {
      if (ch === '*' && next === '/') {
        inBlockComment = false;
        i += 1;
      }
      continue;
    }
    if (inSingle) {
      if (escape) {
        escape = false;
      } else if (ch === '\\') {
        escape = true;
      } else if (ch === "'") {
        inSingle = false;
      }
      continue;
    }
    if (inDouble) {
      if (escape) {
        escape = false;
      } else if (ch === '\\') {
        escape = true;
      } else if (ch === '"') {
        inDouble = false;
      }
      continue;
    }

    if (ch === '/' && next === '/') {
      inLineComment = true;
      i += 1;
      continue;
    }
    if (ch === '/' && next === '*') {
      inBlockComment = true;
      i += 1;
      continue;
    }
    if (ch === "'") {
      inSingle = true;
      continue;
    }
    if (ch === '"') {
      inDouble = true;
      continue;
    }

    if (ch === '{') {
      braceDepth += 1;
    } else if (ch === '}') {
      braceDepth -= 1;
      if (braceDepth === 0) {
        const endIdx = i + 1;
        const snippet = sourceText.slice(sigStartIdx, endIdx).replace(/\n$/, '');
        const startLine = countLinesBefore(sourceText, sigStartIdx);
        return { startLine, snippet };
      }
    }
  }

  throw new Error('zig block: could not find matching closing brace');
}

function extractZigFunction(sourceText, name) {
  const re = new RegExp(`\\bfn\\s+${escapeRegExp(name)}\\b`, 'g');
  const match = re.exec(sourceText);
  if (!match) {
    throw new Error(`func: could not find Zig function ${name}`);
  }
  return extractZigBlock(sourceText, match.index);
}

function extractZigTest(sourceText, name) {
  const re = new RegExp(`\\btest\\s+\"${escapeRegExp(name)}\"\\s*\\{`, 'g');
  const match = re.exec(sourceText);
  if (!match) {
    throw new Error(`zigtest: could not find Zig test ${name}`);
  }
  return extractZigBlock(sourceText, match.index);
}

function parseSnippetSpec(spec) {
  const hashIdx = spec.indexOf('#');
  const relPath = (hashIdx === -1 ? spec : spec.slice(0, hashIdx)).trim();
  const selector = hashIdx === -1 ? '' : spec.slice(hashIdx + 1).trim();

  if (!relPath) {
    throw new Error(`Invalid snippet spec (missing path): ${spec}`);
  }

  if (!selector || selector === 'all') {
    return { relPath, kind: 'all' };
  }

  const lineMatch = selector.match(/^L(\d+)-L(\d+)$/);
  if (lineMatch) {
    return {
      relPath,
      kind: 'lines',
      startLine: parseInt(lineMatch[1], 10),
      endLine: parseInt(lineMatch[2], 10),
    };
  }

  const funcMatch = selector.match(/^func=(\w+)$/);
  if (funcMatch) {
    return { relPath, kind: 'func', name: funcMatch[1] };
  }

  const betweenMatch = selector.match(/^between=(.+)\|(.+)$/);
  if (betweenMatch) {
    return { relPath, kind: 'between', start: betweenMatch[1], end: betweenMatch[2] };
  }

  const zigTestMatch = selector.match(/^zigtest=(.+)$/);
  if (zigTestMatch) {
    return { relPath, kind: 'zigtest', name: zigTestMatch[1] };
  }

  throw new Error(`Unknown snippet selector: ${selector} (in ${spec})`);
}

function updateFenceHeader(headerLine, startLine) {
  if (!headerLine.startsWith('```')) return headerLine;
  if (headerLine.includes('showLineNumbers')) {
    return headerLine.replace(/showLineNumbers(=\d+)?/g, `showLineNumbers=${startLine}`);
  }
  return `${headerLine} showLineNumbers=${startLine}`;
}

function extractSnippet(spec) {
  const sourceText = readSource(spec.relPath);

  if (spec.kind === 'all') {
    const snippet = sourceText.replace(/\n$/, '');
    return { startLine: 1, snippet };
  }
  if (spec.kind === 'lines') {
    return extractLines(sourceText, spec.startLine, spec.endLine);
  }
  if (spec.kind === 'between') {
    return extractBetween(sourceText, spec.start, spec.end);
  }

  const isZig = spec.relPath.endsWith('.zig');
  if (spec.kind === 'func') {
    return isZig ? extractZigFunction(sourceText, spec.name) : extractCFunction(sourceText, spec.name);
  }
  if (spec.kind === 'zigtest') {
    if (!isZig) throw new Error(`zigtest selector only valid for .zig files: ${spec.relPath}`);
    return extractZigTest(sourceText, spec.name);
  }

  throw new Error(`Unhandled snippet kind: ${spec.kind}`);
}

function sourceHref(relPath, startLine, endLine) {
  const base = `${githubBaseUrl}${relPath}`;
  if (!startLine || startLine <= 0) return base;
  if (!endLine || endLine <= 0 || endLine === startLine) return `${base}#L${startLine}`;
  return `${base}#L${startLine}-L${endLine}`;
}

function sourceLabel(relPath, startLine, endLine) {
  if (!startLine || startLine <= 0) return relPath;
  if (!endLine || endLine <= 0 || endLine === startLine) return `${relPath}#L${startLine}`;
  return `${relPath}#L${startLine}-L${endLine}`;
}

function syncDoc(docPath) {
  const raw = fs.readFileSync(docPath, 'utf8');
  const original = normalizeNewlines(raw);

  const lines = original.split('\n');
  let changed = false;

  for (let i = 0; i < lines.length; i += 1) {
    const m = lines[i].match(/<!--\s*snippet:\s*([^>]+?)\s*-->/);
    if (!m) continue;

    const spec = parseSnippetSpec(m[1].trim());
    const { startLine, snippet } = extractSnippet(spec);

    const snippetLines = snippet.replace(/\n$/, '').split('\n');
    const endLine = startLine + snippetLines.length - 1;
    const sourceLine = `<div className="jzx-source">Source: <a href="${sourceHref(
      spec.relPath,
      startLine,
      endLine,
    )}"><code>${sourceLabel(spec.relPath, startLine, endLine)}</code></a></div>`;

    const afterDirective = i + 1;
    if (lines[afterDirective]?.startsWith('<div className="jzx-source">Source:')) {
      if (lines[afterDirective] !== sourceLine) {
        lines[afterDirective] = sourceLine;
        changed = true;
      }
    } else {
      lines.splice(afterDirective, 0, sourceLine);
      changed = true;
    }

    let fenceStart = i + 1;
    while (fenceStart < lines.length && !lines[fenceStart].startsWith('```')) {
      fenceStart += 1;
    }
    if (fenceStart >= lines.length) {
      throw new Error(`No code fence after snippet directive in ${docPath}:${i + 1}`);
    }

    let fenceEnd = fenceStart + 1;
    while (fenceEnd < lines.length && !lines[fenceEnd].startsWith('```')) {
      fenceEnd += 1;
    }
    if (fenceEnd >= lines.length) {
      throw new Error(`Unclosed code fence after snippet directive in ${docPath}:${i + 1}`);
    }

    const updatedHeader = updateFenceHeader(lines[fenceStart], startLine);
    if (updatedHeader !== lines[fenceStart]) {
      lines[fenceStart] = updatedHeader;
      changed = true;
    }

    const current = lines.slice(fenceStart + 1, fenceEnd);
    if (current.join('\n') !== snippetLines.join('\n')) {
      lines.splice(fenceStart + 1, fenceEnd - fenceStart - 1, ...snippetLines);
      changed = true;
      fenceEnd = fenceStart + 1 + snippetLines.length;
    }

    i = fenceEnd;
  }

  const updated = lines.join('\n');
  return { original, updated, changed };
}

let changedCount = 0;

for (const root of deepDiveRoots) {
  for (const docPath of listMarkdownFiles(root)) {
    const { updated, changed } = syncDoc(docPath);
    if (!changed) continue;

    changedCount += 1;
    if (isCheckMode) {
      // eslint-disable-next-line no-console
      console.error(
        `Out of date: ${path.relative(repoRoot, docPath)} (run: npm run sync:deep-dive)`,
      );
    } else {
      fs.writeFileSync(docPath, updated);
      // eslint-disable-next-line no-console
      console.log(`Updated: ${path.relative(repoRoot, docPath)}`);
    }
  }
}

if (isCheckMode && changedCount > 0) {
  process.exitCode = 1;
}
