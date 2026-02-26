# ReScript Monorepo Build Behaviour

## How the root build handles dependency packages

When `rescript build` runs from the monorepo root, it processes all packages listed in the root `rescript.json` `"dependencies"` array. Each dependency is compiled using its own `rescript.json` for source structure, but inherits the root's `"package-specs"` (module format, suffix, in-source flag).

**Critical distinction:** when a package is compiled *as a dependency*, the build system only compiles its `src` source tree. Source directories listed as separate top-level entries in `"sources"` (e.g. a standalone `"examples"` or `"example"` entry) are **not compiled** from a root build. They are only compiled when that package is the root of the build invocation (i.e. you run `rescript build` from within the package directory itself).

This is true regardless of whether those directories have `"type": "dev"` or not.

## The `"public"` field and compilation scope

Setting `"public": ["ModuleName"]` on a source entry signals that only those modules are exposed to consumers. In practice, when the package is built as a dependency, the build system may further restrict compilation to only those public modules, skipping any other source directories that contribute no public modules.

**Consequence:** a `"public"` constraint on `src` can silently prevent sibling source directories (like `examples`) from compiling in dependency builds.

## The correct pattern for example files

Place example files **inside `src/`** as a subdirectory (e.g. `src/examples/`). Because `src` is always compiled in both root and standalone builds, example files will always be compiled:

```json
"sources": [
  {
    "dir": "src",
    "subdirs": true
  }
]
```

```
src/
  Uuid.res
  examples/
    Example.res
```

Do **not** list examples as a separate top-level source entry alongside `src`:

```json
// Wrong — examples are skipped in root dependency builds
"sources": [
  { "dir": "src", "subdirs": true },
  { "dir": "examples", "subdirs": true }
]
```

## What we changed

All `rescript/*` packages that had a separate `example` or `examples` source directory had those directories moved into `src/` and the separate source entry removed:

- `rescript-aws-sdk`: `example/` → `src/example/`
- `rescript-fast-csv`: `examples/` → `src/examples/`
- `rescript-hash-object`: `examples/` → `src/examples/`
- `rescript-node-zlib`: `example/` → `src/example/` (also removed `"public"` constraint)
- `rescript-uuid`: `examples/` → `src/examples/` (also removed `"public"` constraint)

## Diagnosing the same issue in future

If a compiled `.res.mjs` file is present after a package-level build but missing after a root monorepo build, check:

1. Is the source directory listed as a separate top-level entry in `"sources"` (not under `src`)? → Move it into `src/`.
2. Does the `src` source entry have a `"public"` field? → Remove it if not necessary; it can suppress compilation of sibling directories.
3. Does `lib/bs/` only contain artifacts for the `src` modules? → Confirms the root build is skipping the other directory.
