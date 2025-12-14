# libjzx documentation site

This directory contains the libjzx documentation website.

## Prerequisites

This site requires **Node.js 20+**.

Verify:

```sh
node -v
npm -v
```

## Install dependencies

From the repo root:

```sh
cd docs
npm install
```

## Local development

```sh
cd docs
npm run start
```

## Keeping deep-dive pages in sync with source

Some deep-dive pages embed full source files with line numbers. To keep those code blocks synced:

```sh
cd docs
npm run sync:deep-dive
```

CI runs a sync check:

```sh
cd docs
npm run check:deep-dive
```

## Production build

```sh
cd docs
npm run build
```

The static site is generated into `docs/build/`.

## Serve the production build locally

```sh
cd docs
npm run serve
```

## GitHub Pages notes (url/baseUrl)

This site’s configuration automatically chooses a suitable `baseUrl` on GitHub Actions:

- **Project Pages** (most repos): `https://<owner>.github.io/<repo>/`
- **Org/User Pages** (repo named `<owner>.github.io`): `https://<owner>.github.io/`

To override locally or in other CI systems, set:

- `DOCS_URL` (example: `https://rexbrahh.github.io`)
- `DOCS_BASE_URL` (example: `/libjzx/` or `/`)
