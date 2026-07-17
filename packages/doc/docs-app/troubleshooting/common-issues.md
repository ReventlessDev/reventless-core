---
title: Common Issues
date: 2024-08-13
draft: false
---

# Common Issues

## Compiler Warnings

Reventless requires **zero warnings** before committing. After every build, check with:

```bash
npm run build 2>&1 | grep -E "Warning|warning|error|Error"
```

### Warning 44 — Open shadows existing identifier

Caused by opening two modules that export the same name.

```
Warning 44: This open statement shadows the value identifier X (which is later used)
```

**Fix:** Remove the redundant `open`, qualify the ambiguous name explicitly, or add `@@warning("-44")` as a file-level attribute at the very top of the file. Note: `@warning("-44") open X` (field-level) does NOT work in ReScript — it must be `@@warning("-44")` (file-level).

A common cause: `open ReventlessCore` inside tests in the `reventless` package — the package is already in the `ReventlessCore` namespace, so the open is redundant. Remove it.

### Warning 32 — Unused value declaration

```
Warning 32: unused value X.
```

Appears when a module is constrained with `: ModuleType` and the module exports a value not in `ModuleType`. Remove the unused value or add it to the module type.

### Warning 23 — Redundant field in record expression

```
Warning 23: All the fields are explicitly listed in this record: the spread is useless.
```

Caused by `{...state, field: val}` when `state` has only one field. Write `{field: val}` directly. If the original `state` argument becomes unused after this change, prefix it with `_`.

## `Component.js` Overwrite Issue

`reventless-spec/src/components/Component.js` is a **hand-written file** that provides the `class Component extends pulumi.ComponentResource` base class for all framework components.

If `rescript clean && rescript build` is run inside the `reventless-spec/` package directory, the ReScript compiler regenerates `Component.js` as a broken circular-require file.

**Fix:** Restore the correct file from git:

```bash
git checkout -- reventless/spec/src/components/Component.js
```

To prevent this: always run builds from the monorepo root, not from individual package directories.

## `npm ci` Fails / package-lock.json Out of Sync

```
npm error `npm ci` can only install packages when your package.json and package-lock.json are in sync.
```

**Fix:** Run `npm install` (not `npm ci`) to regenerate the lock file, then commit both `package.json` and `package-lock.json` together:

```bash
npm install
git add package.json package-lock.json
git commit -m "chore(deps): sync package-lock.json"
```

GitHub Actions uses `npm ci` which requires the lock file to be in sync.

## Stale ReScript Build Cache

After reorganizing source files (renaming, moving), the ReScript compiler may produce errors from stale cached artifacts.

**Fix:**

```bash
npx rescript clean   # from the package directory
npm run build        # from the monorepo root
```

Or from the root:

```bash
npm run clean && npm run build
```

## Test Failures from Async Handler Registration (DCB E2E)

DCB E2E tests fail with "handler not found" errors because `StateChangeSlice_Builder` registers CommandTopic handlers inside `Output.apply` (asynchronously) — the handlers may not be registered before the first test runs.

**Fix:** Add a `beforeAll` that resolves the Output chain before any tests:

```rescript
open AsyncTest

describe("My DCB Test", () => {
  beforeAllAsync(async () => {
    // Force the Output chain to resolve, triggering handler registration
    let _ = await eventLog->Reventless.Component.operations->ReventlessLocal.TestRunner.resolve
  })

  // ... your tests
})
```

## Issues during Runtime

### `module not found` exception during runtime

Check that the Lambda layer ARN is correctly configured. See [Getting Started with AWS](/infrastructure/aws/get-started) for layer setup instructions.

### Scheduler not triggering

CloudWatch Events has a limit of 300 rules per region per account. If you exceed this limit, new rules cannot be created and the scheduler will not trigger.

Check the CloudWatch Events console for rule creation errors and consider consolidating scheduler configurations.
