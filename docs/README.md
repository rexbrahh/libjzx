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

Deep-dive pages embed source snippets with line numbers and a “Source: <path>#Lx-Ly” link back to GitHub.

To keep those code blocks (and their line ranges) synced with the repo:

```sh
cd docs
npm run sync:deep-dive
```

CI runs a sync check:

```sh
cd docs
npm run check:deep-dive
```

If you intentionally want to update the **versioned** deep-dive snapshots too (rare), run:

```sh
cd docs
npm run sync:deep-dive:all
```

## Deep-dive coverage check

Deep-dive pages are intended to cover all **non-empty** lines of the core runtime/build/tooling/example sources
(excluding `#all` appendices).

Generate a coverage report:

```sh
cd docs
npm run coverage:deep-dive
```

CI enforces the coverage target:

```sh
cd docs
npm run check:coverage:deep-dive
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

## Documentation versioning

This site uses Docusaurus docs versioning.

- The currently published/stable docs are **v0.0.1**.
- The working directory `docs/docs/` is treated as **next** (unreleased) and is available under `/docs/next/` when running locally.

To snapshot the current `docs/docs/` as a new released version:

```sh
cd docs
npm run docusaurus -- docs:version 0.0.2
```
