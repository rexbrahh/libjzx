import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

const sidebars: SidebarsConfig = {
  docsSidebar: [
    {
      type: 'category',
      label: 'Orientation',
      collapsed: false,
      link: {
        type: 'generated-index',
        slug: '/orientation',
        title: 'Orientation',
        description:
          'Start here if you are new: high-level mental model, invariants, and how to read the code-first deep dive.',
      },
      items: ['intro', 'concepts/architecture', 'concepts/design-goals'],
    },
    {
      type: 'category',
      label: 'Using libjzx',
      collapsed: false,
      link: {
        type: 'generated-index',
        slug: '/using',
        title: 'Using libjzx',
        description:
          'Build/run examples, configure the runtime, debug common issues, and keep reference pages close at hand.',
      },
      items: [
        'getting-started/installation',
        'getting-started/quickstart',
        'guides/configuration',
        'guides/troubleshooting',
        'reference/config-reference',
        'reference/api',
        'reference/cli',
      ],
    },
    {
      type: 'category',
      label: 'Deep Dive (Code)',
      collapsed: true,
      link: {
        type: 'generated-index',
        slug: '/deep-dive',
        title: 'Deep Dive (Code)',
        description:
          'Textbook-style walkthroughs of every core file and example, with small snippets and line-scoped “Source:” links.',
      },
      items: [
        {
          type: 'category',
          label: 'Build System',
          collapsed: true,
          items: ['deep-dive/build-zig-zon', 'deep-dive/build-zig'],
        },
        {
          type: 'category',
          label: 'Public API',
          collapsed: true,
          items: ['deep-dive/include-jzx-jzx-h', 'deep-dive/zig-jzx-lib-zig'],
        },
        {
          type: 'category',
          label: 'Runtime',
          collapsed: true,
          items: [
            'deep-dive/src-jzx-internal-h',
            'deep-dive/src-jzx-runtime-c',
            'deep-dive/src-jzx-xev-zig',
          ],
        },
        {
          type: 'category',
          label: 'Tests + Stress',
          collapsed: true,
          items: ['deep-dive/zig-tests-basic-zig', 'deep-dive/tools-stress-zig'],
        },
        {
          type: 'category',
          label: 'Examples',
          collapsed: true,
          items: [
            'deep-dive/examples-zig-ping-zig',
            'deep-dive/examples-zig-typed-actor-zig',
            'deep-dive/examples-zig-supervisor-zig',
            'deep-dive/examples-zig-echo-server-zig',
            'deep-dive/examples-c-loop-c',
            'deep-dive/examples-c-supervisor-c',
          ],
        },
      ],
    },
    {
      type: 'category',
      label: 'Contributing',
      collapsed: true,
      link: {
        type: 'generated-index',
        slug: '/contributing',
        title: 'Contributing',
        description: 'Development workflow, formatting, tests, docs, and security reporting.',
      },
      items: ['contributing/contributing', 'security'],
    },
    {
      type: 'category',
      label: 'Releases',
      collapsed: true,
      link: {
        type: 'generated-index',
        slug: '/releases',
        title: 'Releases',
        description: 'Version snapshots and “what changed” notes.',
      },
      items: ['releases/next'],
    },
  ],
};

export default sidebars;
