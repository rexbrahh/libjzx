import path from 'node:path';
import {visitParents} from 'unist-util-visit-parents';
import type {Root, Parent} from 'mdast';
import type {VFile} from 'vfile';

type Target = {
    docId: string;
    anchor?: string;
};

const SYMBOL_RE = /^(jzx_[a-z0-9_]+|JZX_[A-Z0-9_]+)$/;

function resolveSymbol(symbol: string): Target | null {
    // Public API and types live on the C ABI deep-dive page.
    const docId = 'deep-dive/include-jzx-jzx-h';

    // Types (lowercase) and error model.
    if (symbol === 'jzx_err') return {docId, anchor: 'error-model'};
    if (symbol === 'jzx_actor_id' || symbol === 'jzx_loop') return {docId, anchor: 'core-identifiers'};
    if (symbol === 'jzx_allocator') return {docId, anchor: 'allocator-interface'};
    if (symbol === 'jzx_msg') return {docId, anchor: 'message-envelope'};
    if (symbol === 'jzx_behavior') return {docId, anchor: 'behavior-interface'};
    if (symbol === 'jzx_config') return {docId, anchor: 'runtime-config'};

    // Error codes and tags.
    if (symbol === 'JZX_OK' || symbol.startsWith('JZX_ERR_')) return {docId, anchor: 'error-model'};
    if (symbol.startsWith('JZX_TAG_')) return {docId, anchor: 'message-envelope'};

    // Supervisors/restart policy enums live under supervision.
    if (symbol.startsWith('JZX_RESTART_') || symbol.startsWith('JZX_CHILD_') || symbol.startsWith('JZX_SUPERVISOR_')) {
        return {docId, anchor: 'supervision'};
    }

    // Functions: map to the section that defines their contract.
    if (!symbol.startsWith('jzx_')) return null;

    if (symbol.startsWith('jzx_loop_set_observer') || symbol.startsWith('jzx_observer')) {
        return {docId, anchor: 'observability'};
    }
    if (symbol.startsWith('jzx_send')) return {docId, anchor: 'messaging'};
    if (
        symbol.startsWith('jzx_timer') ||
        symbol.startsWith('jzx_watch') ||
        symbol.startsWith('jzx_unwatch') ||
        symbol.startsWith('jzx_io_')
    ) {
        return {docId, anchor: 'timers-and-io'};
    }
    if (symbol.startsWith('jzx_spawn') || symbol.startsWith('jzx_supervisor')) return {docId, anchor: 'spawning'};
    if (symbol.startsWith('jzx_config_')) return {docId, anchor: 'runtime-config'};
    if (symbol.startsWith('jzx_loop_')) return {docId, anchor: 'loop-lifecycle'};

    return null;
}

function docsSourceRootForFile(filePath: string): string | null {
    const normalized = filePath.split(path.sep).join(path.posix.sep);
    const versionedMatch = normalized.match(/^(.*)\/versioned_docs\/(version-[^/]+)\//);
    if (versionedMatch) {
        return `${versionedMatch[1]}/versioned_docs/${versionedMatch[2]}`;
    }

    const nextMatch = normalized.match(/^(.*)\/docs\//);
    if (nextMatch) {
        return `${nextMatch[1]}/docs`;
    }

    return null;
}

function relativeDocLink(fromFilePath: string, target: Target): string | null {
    const root = docsSourceRootForFile(fromFilePath);
    if (!root) return null;

    const from = fromFilePath.split(path.sep).join(path.posix.sep);
    const relFrom = path.posix.relative(root, from);
    const fromDir = path.posix.dirname(relFrom);

    const relTo = path.posix.relative(fromDir === '.' ? '' : fromDir, target.docId);
    const base = relTo.length === 0 ? '.' : relTo;
    return target.anchor ? `${base}#${target.anchor}` : base;
}

export default function jzxAutolink() {
    return (tree: Root, file: VFile) => {
        const filePath = file.path ?? '';

        visitParents(tree, 'inlineCode', (node: any, ancestors: Parent[]) => {
            const value = String(node.value ?? '');
            if (!SYMBOL_RE.test(value)) return;

            // Avoid nested links.
            const parent = ancestors[ancestors.length - 1];
            if (!parent || parent.type === 'link') return;

            const target = resolveSymbol(value);
            if (!target) return;

            const url = relativeDocLink(filePath, target);
            if (!url) return;

            const idx = (parent.children as any[]).indexOf(node);
            if (idx === -1) return;

            (parent.children as any[])[idx] = {
                type: 'link',
                url,
                title: `See ${target.docId}${target.anchor ? `#${target.anchor}` : ''}`,
                children: [node],
            };
        });
    };
}

