---
title: Running Tests
date: 2026-02-27
draft: false
---

This guide covers how to run the test suite locally. Tests are written in ReScript and compiled to `.res.mjs` files before Jest picks them up, so you need a working build before running tests.

## Prerequisites

Make sure dependencies are installed and the project is built:

```bash
npm install
npm run build
```

## Running All Tests

From the repository root, run the full test suite across all packages:

```bash
npm test
```

This runs Jest across all 8 projects in a single pass and prints a unified summary:

```
PASS reventless-core AggregateCallbackTest (7 tests, 0.320s)
PASS reventless-core DcbTagTest (33 tests, 0.265s)
...
PASS example-dcb-catalog CatalogE2ETest (9 tests, 3.225s)

Test Suites: 69 passed, 69 total
Tests:       579 passed, 579 total
Time:        7.0 s
```

## Watch Mode

Watch mode re-runs tests automatically whenever compiled `.res.mjs` files change.

### Tests only

```bash
npm run test:watch          # show all results
npm run test:watch:fail     # show only failing tests
```

### ReScript compiler + tests together

The `dev` commands run the ReScript compiler in watch mode alongside Jest, so saving a `.res` source file triggers a compile-then-test cycle automatically:

```bash
npm run dev                 # show all results
npm run dev:fail            # show only failing tests
```

ReScript output is prefixed with `[rs]` in cyan, Jest output with `[jest]` in yellow.

:::tip
Use `dev` or `dev:fail` as your normal development loop — edit a `.res` file, save, and see test results update within seconds.
:::

## Running a Single Package

Navigate to the package directory and run its tests directly:

```bash
cd reventless/reventless-core
npm test

cd reventless/reventless-in-memory
npm test

cd examples/dcb/catalog
npm test
```

Per-package watch mode:

```bash
npm run dev      # jest --watchAll
```

## Running a Single Test File

From a package directory, pass the file path to Jest directly:

```bash
cd reventless/reventless-core
NODE_OPTIONS='--experimental-vm-modules' npx jest tests/aggregate/AggregateCallbackTest.res.mjs
```

You can also use a partial name pattern:

```bash
NODE_OPTIONS='--experimental-vm-modules' npx jest AggregateCallback
```

## See Also

- [Writing Unit Tests](./writing-unit-tests.md) — how to write tests for your aggregates and read models
