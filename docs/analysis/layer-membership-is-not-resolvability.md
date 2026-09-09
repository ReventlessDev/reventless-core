# The Lambda archive asked the wrong question about the layer

**Date:** 2026-09-09
**Status:** ✅ FIXED in `Util_Bundle.res`, with regression tests in
`Util_BundleDependencyClosureTest.res` and the mechanism documented under
*What the layer holds, and what the archive must carry* in the lambda-deployment guide.

## Symptom

A green deploy whose slice dies at its **first command**:

```
Lambda:Unhandled — Cannot find package '@reventlessdev/trait-attachments'
imported from /var/task/node_modules/<plugin>/src/Category/StateChange/CategoryImages.res.mjs
```

The package is installed, and it is a declared dependency of the plugin package.
Nothing in the deploy output mentions it.

## What was wrong

`buildCodeArchive` splits packages in two: the layer carries the framework's, the
archive carries the plugin's. `isFrameworkPackage` decided which side a package
fell on, and it decided by asking whether `require.resolve` reaches the package
**from this module** — a stand-in for "the layer has it", on the reasoning that
the layer is built from reventless-aws's closure.

The stand-in does not hold, because **Node's resolution walks up**. In a consumer
repo with a hoisted `node_modules`, every package sits at the workspace root,
which is on the walk-up path from
`node_modules/@reventlessdev/reventless-aws/src/util/`. So the predicate answered
`true` for every package in the tree — plugin packages, their traits, everything.

Two effects, and the second is the larger one:

1. A plugin's dependency was **excluded from the archive** as layer-provided,
   when the layer had never held it.
2. The plugin package itself also answered `true`, so it was filtered out of
   `addImportedPackageClosure`'s **starting points** — the walk had nothing to
   walk from and did nothing at all. The closure feature was inert in exactly the
   repos it was written for.

This repo cannot reproduce it. Its traits live in `traits/`, outside what the
framework resolves, so the predicate happens to answer correctly here. The bug is
only visible from a consumer.

## The fix

Ask the question the split actually turns on: **is the package in the layer?**

The layer builder runs a production npm install of `@reventlessdev/reventless-aws`,
so its content is that package's transitive `dependencies`. `frameworkPackages`
now walks exactly those edges, resolving each from the declaring package's own
directory so a pnpm layout resolves as the runtime would, and `isFrameworkPackage`
tests membership.

`devDependencies` are deliberately not read — the layer is a production install.

### The layer is the closure *plus* an explicit list

`includeModules` in the layer builder's config adds packages the closure misses.
`@rescript/runtime` is the one that matters: it is a transitive of `rescript`,
which the layer excludes as a build tool, so it is absent from the production
closure while the layer carries it — and every compiled ReScript file imports it.

Modelling only the closure would have made it a user package and put **19 MB into
every archive**. `layerIncludedModules` mirrors that list, and says where its
other half lives so the two stay in step.

The layer's `excludeModules` are not mirrored. Those are deploy-time-only packages
— the @pulumi bindings, esbuild, the SSH stack — and the walk is import-driven, so
a package no runtime file imports never comes up.

## Why the tests would have caught it

The existing fixtures used `@fixture/*` names that resolve nowhere, so they passed
under both implementations. The added cases assert the predicate directly on
packages that **do** resolve from here but are **not** in the closure — a real
published package outside reventless-aws's dependencies answers `false`, and
`@rescript/runtime` answers `true` despite being outside it. Both fail on the old
implementation.

## The lesson worth keeping

Scope is not membership, and neither is resolvability. A `@reventlessdev/`-scoped
package may be a plugin's, and a package the framework can resolve may be one the
layer never had. Where a wrong answer is a green deploy that fails at the first
command, the predicate has to be computed from the thing it claims to describe —
here, the dependency closure the layer is actually built from.
