---
title: Next (unreleased)
sidebar_position: 1
---

# Next (unreleased)

These docs describe the **current working tree** under `docs/docs/` and may diverge from the last published snapshot (**v0.0.1**).

<Why>
The goal of a “next” version is to let the docs evolve alongside the code without rewriting history.
When a set of changes stabilizes, snapshot `next` into a new version (for example `0.0.2`) so readers can pin to known behavior.
</Why>

## What changed since v0.0.1

TODO: Summarize user-visible changes here (API changes, semantics changes, new examples).

Suggested structure:

- **API surface**: added/removed/changed functions and types (with links to the deep dive)
- **Runtime semantics**: scheduling fairness, mailbox behavior, supervision rules
- **Tooling**: build graph changes, CI changes, docs-site changes
- **Migration notes**: if a change requires code updates

## How to publish a new version

From `docs/`:

```sh
npm run docusaurus -- docs:version 0.0.2
```

This snapshots `docs/docs/` into `docs/versioned_docs/version-0.0.2/` and records it in `docs/versions.json`.

