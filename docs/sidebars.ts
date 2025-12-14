import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

const sidebars: SidebarsConfig = {
  docsSidebar: [
    {
      type: 'category',
      label: 'Orientation',
      collapsed: false,
      items: ['intro', 'concepts/architecture', 'concepts/design-goals'],
    },
    {
      type: 'category',
      label: 'Using libjzx',
      collapsed: false,
      items: [
        'getting-started/installation',
        'getting-started/quickstart',
        'guides/configuration',
        'guides/troubleshooting',
        'reference/config-reference',
        'reference/cli',
      ],
    },
    {
      type: 'category',
      label: 'Deep Dive (Code)',
      collapsed: true,
      link: {type: 'doc', id: 'deep-dive/source-index'},
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
      items: ['contributing/contributing', 'security'],
    },
  ],
};

export default sidebars;
