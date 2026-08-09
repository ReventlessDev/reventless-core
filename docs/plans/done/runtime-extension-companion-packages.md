# Plan: Bundle a Runtime Extension's Companion Packages

**Status**: Done (2026-08-09) — implemented the day it was planned; unit acceptance green. The live criterion (a deployed runtime firing a companion-carrying extension at cold start) awaits the next real deployment of such an extension — same caveat the seam plan itself was closed with. Follow-up to [runtime-extension-seam.md](runtime-extension-seam.md), prompted by the first live deployment of a registered extension.
**Sibling plans**: [adapter-seam-generalizations.md](../adapter-seam-generalizations.md)

## Problem

`Util_Bundle.addRuntimeExtensionPackages` bundles exactly one package per registered
extension: the package that owns the module named by `moduleUrl`. Nothing carries the
packages that module *imports*. An extension whose artifact statically imports a
companion package — one that is neither part of the framework set already in the
archive (`@reventlessdev/reventless-core`, `@reventlessdev/reventless-aws`, `effect`)
nor reachable through the layer fallback dirs — fails to load at cold start:

```
cold-start extension "<pkg>/src/X_Extension.res.mjs" could not be loaded; skipped:
Cannot find package '<companion>' imported from /var/task/node_modules/<pkg>/...
```

The entry shell catches the load failure by design (a broken extension must not take
the runtime down), logs at ERROR and fires zero extensions — so the feature the
extension carries is silently off in every runtime, on every cold start, while the
deploy is green. This was observed live on the seam's first real deployment: the
acceptance check the seam plan prescribed ("confirm the shell's import resolves under
`/var/task/node_modules`") is currently only checkable *after* the deploy, from the
runtime's own logs.

Two facts make this unreachable by conventional means:

- **A `dependencies` walk finds nothing.** The ecosystem convention for split
  packages (a provider arm over a neutral core) declares the neutral package as a
  `peerDependency`, precisely so the deploy program shares one instance. Peers are
  the "already present in the process" contract — which is true in the deploy
  program and false in the Lambda.
- **Framework-rooted resolution cannot find companions.** The extension is an
  out-of-tree package; `addRuntimeExtensionPackages` only finds *it* because
  `getModuleSpecifier` walks up from the module's own file path. A companion named
  by bare package name would need a resolution root the framework does not have.

The one thing that resolves robustly is the same thing the seam already relies on:
a module URL the companion package states about itself.

## Fix

Extend the extension contract so an extension declares the companion packages its
runtime import graph reaches, the same way it declares itself:

```rescript
module type Extension = {
  let moduleUrl: string
  /** `import.meta.url` of one module per companion package this extension imports
      at runtime — packages that must ride into the archive alongside the
      extension's own. Empty for an extension with no imports outside the
      framework-provided set. */
  let companionModuleUrls: array<string>
  let onColdStart: coldStartHook
}
```

- `Util_Bundle.addRuntimeExtensionPackages` maps companion URLs through the existing
  `getModuleSpecifier` → `extractPackageName` → `resolvePackageRoot` pipeline and
  adds each package to `packageDirs` — identical treatment to the extension package
  itself, deduplicated by the dict.
- `RUNTIME_EXTENSIONS` is unchanged: companions are bundle-only; the entry shell
  imports only the extension modules, and Node resolves companions from
  `/var/task/node_modules` like any other import.
- A companion package exposes a URL by exporting
  `let moduleUrl: string = %raw("import.meta.url")` from any module the extension
  already imports (spec modules can lift the `@@reventless.spec`-injected one).
- Breaking for the module type at alpha: existing extensions add
  `let companionModuleUrls = []`.

The registry (`RuntimeExtension.moduleUrls`) grows a sibling
(`companionModuleUrls()` flattened, registration order) read only by the bundler.
`isEmpty` and the byte-identical-when-empty guarantee are untouched.

## Guard: fail the deploy, not the cold start

Declaring companions is still something an author must remember, and the current
failure mode is the worst kind: green deploy, silent runtime no-op. Add a
deploy-time check in `buildCodeArchive` when `bundleRuntimeExtensions` is on:

1. Parse the static top-level `import` specifiers of each registered extension
   artifact (and, transitively, of files inside packages added to the archive by
   this mechanism).
2. Assert every bare package specifier is present in `packageDirs` or in the known
   runtime-provided set (framework packages, layer contents, `node:*`).
3. On a miss, throw at archive build — naming the extension, the specifier, and the
   `companionModuleUrls` remedy.

Static parsing is a partial truth (dynamic `import()` escapes it), which is exactly
why it is the *check* and not the *mechanism*: a false negative in the check still
lands on the explicit declaration; the declaration never depends on parsing.

## Alternative considered

Auto-bundle from the parsed import graph, with no declaration at all. Rejected as
the mechanism: exports maps and dynamic imports make parsing an approximation, and
the seam's idiom is explicit registration — an extension states what it needs, the
framework carries it. The parse pass earns its keep as the loud guard instead.

## Acceptance

- ✅ Unit: an extension declaring one companion → archive contains both packages under
  `node_modules/`; `sourceCodeHash` shifts when the companion's content shifts
  (`reventless/aws/tests/Util_BundleRuntimeExtensionTest.res`).
- ✅ Unit: empty registry → archive byte-identical to today (same suite — asserted
  against a `~bundleRuntimeExtensions=false` build).
- ✅ Unit: extension importing an undeclared, un-bundled package → archive build throws,
  naming the package, the file, the specifier and the `companionModuleUrls` remedy.
- ⏳ Live: a runtime provisioned from an extension with a companion fires the hook at
  cold start (`firing 1 cold-start extension(s)` in the runtime log, no
  `could not be loaded`). Pending the next real deployment.

## Implementation notes (as landed, 2026-08-09)

- Seam: `RuntimeExtension.Extension` gains `companionModuleUrls`; registry gains
  `companionModuleUrls()` (flattened, registration order). `moduleUrls`, `isEmpty`
  and `RUNTIME_EXTENSIONS` untouched — companions are bundle-only.
- Bundler: `Util_Bundle.addRuntimeExtensionPackages` maps companion URLs through the
  same `getModuleSpecifier` → `extractPackageName` → `resolvePackageRoot` pipeline
  and now returns the packages it added (name → root) — the set the guard scans.
- Guard: `Util_Bundle.assertRuntimeExtensionImportsResolvable`, called from
  `buildCodeArchive` after the extension packages are added. Static `import` /
  re-`export` specifiers are extracted per bundled file (regex; `import`
  declarations are top-level-only in ESM, dynamic `import()` deliberately escapes);
  a bare specifier passes when it is bundled (`packageDirs`), a Node builtin, in the
  `@aws-sdk`/`@smithy` scopes (ESM fallback dirs), or resolvable from the framework
  root — the approximation of the Lambda layer, which bundles reventless-aws's
  dependency closure. `node:module`'s `builtinModules` got a binding in
  `rescript-node` for this.

## Docs

- Update [runtime-extension-seam.md](runtime-extension-seam.md)'s capability
  table row ("Extension packages bundled into the archive") to note companions.
- The extension-author section of the adapter guide gains the rule of thumb:
  framework packages → peers (already in the archive); everything else your module
  imports → `companionModuleUrls`.
