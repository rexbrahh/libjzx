---
title: Dependency manifest — build.zig.zon
---

# Dependency manifest — `build.zig.zon`

`build.zig.zon` is Zig’s **package/dependency manifest** for this repository.

It answers questions like:

- Which Zig version is this repo intended to build with?
- What external dependencies exist (and which exact revision is pinned)?
- Which files/dirs are part of the package when used as a dependency?

This page is written in a “textbook” style: small code snippets surrounded by the explanation of what they mean and why they exist.

## The top-level object

`build.zig.zon` is a Zig struct literal (a “ZON” file) describing the package.

<!-- snippet: build.zig.zon#L1-L5 -->
```zig title="Package identity + minimum Zig version" showLineNumbers=1
.{
    .name = .libjzx,
    .version = "0.0.1",
    .fingerprint = 0x5b762b24f9b0f9a,
    .minimum_zig_version = "0.15.1",
```

What each field means:

- `.name = .libjzx`: the package name, as an identifier.
  - Why it exists: other Zig projects will refer to this name when adding the dependency.
- `.version = "0.0.1"`: semantic version of the package (string).
  - Why it exists: useful metadata for releases and tooling.
- `.fingerprint = ...`: a content fingerprint used by Zig’s package tooling.
  - Why it exists: helps Zig detect changes and manage caches reproducibly.
- `.minimum_zig_version = "0.15.1"`: an explicit compatibility floor.
  - Why it exists: Zig’s build API evolves; pinning a minimum prevents confusing “works on my machine” issues.

## Dependencies (pinned external code)

libjzx depends on `libxev`, and the dependency is pinned to a specific archive URL + hash.

<!-- snippet: build.zig.zon#L6-L11 -->
```zig title="Dependency table" showLineNumbers=6
    .dependencies = .{
        .libxev = .{
            .url = "https://github.com/mitchellh/libxev/archive/a86bdc692b384f692a99047466ec89c3705d861c.tar.gz",
            .hash = "libxev-0.0.0-86vtcz8bEwB9PLXxMMckZwulRxoKleuLsrffobuUv993",
        },
    },
```

Key ideas:

- The dependency name is `.libxev`.
  - That name must match what `build.zig` requests via `b.dependency("libxev", ...)`.
- `.url` points at a tarball snapshot of a specific commit.
  - Why it exists: builds become reproducible (everyone uses the same libxev revision).
- `.hash` is the integrity/content hash for the downloaded archive.
  - Why it exists: prevents supply-chain substitution and ensures Zig caches the right contents.

## Package “paths” (what’s included when used as a dependency)

`.paths` tells Zig which repo paths are considered part of the package.

<!-- snippet: build.zig.zon#L12-L25 -->
```zig title="Package paths" showLineNumbers=12
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "include",
        "src",
        "zig",
        "examples",
        "tests",
        "README.md",
        "AGENTS.md",
        "dev_logs",
        "docs",
    },
}
```

Why this matters:

- When another Zig project depends on `libjzx`, these are the files/directories it can “see”.
- Keeping this list explicit avoids accidentally depending on local-only files.

Notes:

- Including `docs/` is convenient for in-repo development, but it can increase dependency size for downstream users.
  - If that becomes undesirable, you can remove `docs` from the list without impacting the runtime itself.

## Full listing (for reference)

<!-- snippet: build.zig.zon#all -->
```zig title="build.zig.zon" showLineNumbers=1
.{
    .name = .libjzx,
    .version = "0.0.1",
    .fingerprint = 0x5b762b24f9b0f9a,
    .minimum_zig_version = "0.15.1",
    .dependencies = .{
        .libxev = .{
            .url = "https://github.com/mitchellh/libxev/archive/a86bdc692b384f692a99047466ec89c3705d861c.tar.gz",
            .hash = "libxev-0.0.0-86vtcz8bEwB9PLXxMMckZwulRxoKleuLsrffobuUv993",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "include",
        "src",
        "zig",
        "examples",
        "tests",
        "README.md",
        "AGENTS.md",
        "dev_logs",
        "docs",
    },
}
```
