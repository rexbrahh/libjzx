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
      label: 'Runtime Concepts',
      collapsed: false,
      items: ['concepts/architecture', 'concepts/design-goals'],
    },
    {
      type: 'category',
      label: 'Public API + Reference',
      collapsed: true,
      items: [
        'deep-dive/include-jzx-jzx-h',
        'deep-dive/zig-jzx-lib-zig',
        'reference/cli',
        'reference/config-reference',
      ],
    },
    {
      type: 'category',
      label: 'Internals (Source Walkthroughs)',
      collapsed: true,
      link: {type: 'doc', id: 'deep-dive/source-index'},
      items: [
        'deep-dive/src-jzx-internal-h',
        'deep-dive/src-jzx-runtime-c',
        'deep-dive/src-jzx-xev-zig',
        'deep-dive/zig-tests-basic-zig',
      ],
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
