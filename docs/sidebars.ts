import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

const sidebars: SidebarsConfig = {
  docsSidebar: [
    {
      type: 'category',
      label: 'Getting Started',
      collapsed: false,
      items: ['intro', 'getting-started/installation', 'getting-started/quickstart'],
    },
    {
      type: 'category',
      label: 'Build + Toolchain',
      collapsed: false,
      items: ['deep-dive/build-zig-zon', 'deep-dive/build-zig', 'reference/cli'],
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
    {
      type: 'category',
      label: 'Concepts',
      collapsed: true,
      items: ['concepts/architecture', 'concepts/design-goals'],
    },
    {
      type: 'category',
      label: 'Public API',
      collapsed: true,
      items: [
        'deep-dive/include-jzx-jzx-h',
        'deep-dive/zig-jzx-lib-zig',
        'reference/config-reference',
      ],
    },
    {
      type: 'category',
      label: 'Runtime Internals',
      collapsed: true,
      link: {type: 'doc', id: 'deep-dive/source-index'},
      items: [
        'deep-dive/src-jzx-internal-h',
        'deep-dive/src-jzx-runtime-c',
        'deep-dive/src-jzx-xev-zig',
      ],
    },
    {
      type: 'category',
      label: 'Testing + Stress',
      collapsed: true,
      items: ['deep-dive/zig-tests-basic-zig', 'deep-dive/tools-stress-zig'],
    },
    {
      type: 'category',
      label: 'Guides',
      collapsed: true,
      items: ['guides/configuration', 'guides/troubleshooting'],
    },
    {
      type: 'category',
      label: 'Project',
      collapsed: true,
      items: ['contributing/contributing', 'security'],
    },
  ],
};

export default sidebars;
