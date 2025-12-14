import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

// This runs in Node.js - Don't use client-side code here (browser APIs, JSX...)

function normalizeBaseUrl(value: string): string {
  if (value === '/') return '/';
  let baseUrl = value;
  if (!baseUrl.startsWith('/')) baseUrl = `/${baseUrl}`;
  if (!baseUrl.endsWith('/')) baseUrl = `${baseUrl}/`;
  return baseUrl;
}

const defaultBranch = 'main';
const [organizationName, projectName] = (process.env.GITHUB_REPOSITORY ?? 'rexbrahh/libjzx').split(
  '/',
);

const isGithubActions = process.env.GITHUB_ACTIONS === 'true';
const isOrgPages = projectName === `${organizationName}.github.io`;

const siteUrl = process.env.DOCS_URL ?? `https://${organizationName}.github.io`;
const siteBaseUrl = normalizeBaseUrl(
  process.env.DOCS_BASE_URL ?? (isGithubActions && !isOrgPages ? `/${projectName}/` : '/'),
);

const config: Config = {
  title: 'libjzx',
  tagline: 'libxev-backed actor runtime',
  favicon: 'img/favicon.svg',

  future: {
    v4: true,
  },

  // Set the production url of your site here
  url: siteUrl,
  // Set the /<baseUrl>/ pathname under which your site is served
  // For GitHub pages deployment, it is often '/<projectName>/'
  baseUrl: siteBaseUrl,

  trailingSlash: false,

  // GitHub pages deployment config.
  // If you aren't using GitHub pages, you don't need these.
  organizationName, // Usually your GitHub org/user name.
  projectName, // Usually your repo name.

  onBrokenLinks: 'throw',

  // Even if you don't use internationalization, you can use this field to set
  // useful metadata like html lang. For example, if your site is Chinese, you
  // may want to replace "en" with "zh-Hans".
  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: './sidebars.ts',
          editUrl: `https://github.com/${organizationName}/${projectName}/edit/${defaultBranch}/docs/`,
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    colorMode: {
      respectPrefersColorScheme: true,
    },
    navbar: {
      title: 'libjzx',
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'docsSidebar',
          position: 'left',
          label: 'Docs',
        },
        {
          href: `https://github.com/${organizationName}/${projectName}`,
          label: 'GitHub',
          position: 'right',
        },
      ],
    },
    footer: {
      style: 'light',
      links: [
        {
          title: 'Documentation',
          items: [
            {
              label: 'Introduction',
              to: '/docs/intro',
            },
          ],
        },
        {
          title: 'Links',
          items: [
            {
              label: 'Issues',
              href: `https://github.com/${organizationName}/${projectName}/issues`,
            },
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} libjzx contributors.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.github,
      additionalLanguages: ['zig', 'bash', 'diff'],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
