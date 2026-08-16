---
title: Running tests
sidebar_label: Running tests
---

# Running tests

Scenarios are ReScript sources that compile to `.res.mjs` before Jest sees them,
so **a test run needs a build first**. That is the one fact behind most confusing
test failures: a stale build runs stale scenarios.

## Set up a plugin package for tests

Add Jest and the scenario DSL as dev dependencies:

```bash
pnpm add -D @reventlessdev/reventless-gwt jest
```

Then point Jest at the compiled output and give it the ESM flag:

```json
{
  "scripts": {
    "build": "rescript build",
    "test": "NODE_OPTIONS='--experimental-vm-modules' npx jest",
    "dev": "npx jest --watchAll"
  },
  "jest": {
    "testMatch": [
      "<rootDir>/tests/**/*Test.res.mjs",
      "<rootDir>/tests/**/*_GWT.res.mjs"
    ],
    "moduleFileExtensions": ["js", "mjs"]
  }
}
```

:::caution The ESM flag is not optional
Compiled scenarios are ES modules, so Jest needs
`NODE_OPTIONS='--experimental-vm-modules'` to load them at all. Without it
**every** suite fails with `SyntaxError: Cannot use import statement outside a
module` — which looks like a broken test suite rather than a missing flag. Always
run tests through the `test` script that sets it, never a bare `npx jest`.
:::

## The loop

```bash
pnpm run build     # compile .res → .res.mjs
pnpm test          # run every scenario in the package
```

For a tight loop, run the ReScript compiler in watch mode in one terminal and
`pnpm run dev` (Jest `--watchAll`) in another: saving a `.res` file recompiles it
and Jest re-runs the affected suites within seconds.

## Where scenarios live

Mirror `src/` under `tests/`, one scenario file per spec:

```
src/Category/StateChangeSlice/AddCategory.res
tests/Category/StateChangeSlice/AddCategory_GWT.res
```

The `_GWT` suffix is what wires the file up: the file-level `@@reventless.gwt`
annotation finds the matching spec from the filename and pulls in the
Given/When/Then vocabulary, so the test body is only the scenarios themselves.
See [Writing scenarios](./given-when-then.md) for the DSL.

## Running a subset

Jest takes a path pattern, so any fragment of a filename works:

```bash
pnpm test AddCategory          # one spec's scenarios
pnpm test tests/Category       # one entity's folder
```

In a multi-package repository, run tests from the package directory rather than
the root — the root run compiles and executes everything, which is the right
thing before a commit and the wrong thing while iterating.

## When a run looks wrong

- **Every suite fails to load** — the ESM flag is missing (see above).
- **A change you just made has no effect** — the build did not run, or ran in a
  different package. Rebuild, then re-run.
- **A suite disappeared from the run** — check the compiled `.res.mjs` exists;
  a compile error in one file leaves the previous output in place, so the suite
  silently runs an older version.

## See also

- [Writing scenarios](./given-when-then.md) — the Given/When/Then DSL
- [Component testing guide](./component-testing-guide.md) — integration-level
  tests against a running local platform
