# Plan: `generate-platform` beyond the example topology

**Date:** 2026-07-30
**Status:** **Complete (2026-07-30).** All three gaps closed; each step's outcome is recorded inline.
Written from a real adoption attempt against a platform that is not one of this repo's examples — the
generator refused to run there, for three independent reasons.
**Repos:** `reventless-core` only.
**Builds on:** [platform-capability-provisioning-stage-3.md](./platform-capability-provisioning-stage-3.md),
whose step 3 shipped the generator.

## What Stage 3 assumed

Stage 3's step 3 resolves a plugin's `capabilities.json` from its deploy path in two ways:

1. `<path>/src/capabilities.json` — the path is a composition package.
2. otherwise, parse the `-aws` root's own `generate: generate-plugin --aws <Namespace> <srcDir>`
   script and read `<path>/<srcDir>/capabilities.json`.

Both hold for every example in this repo, which is why the step verified cleanly. Neither is a
property of the *framework's* deployment model — they are properties of how the examples happen to
be laid out. A platform assembled the way the framework advertises (deploy roots that consume
**published** plugin packages) satisfies neither, and the generator does not degrade: it calls
`fail`, which is `process.exit(1)`.

## The three gaps, in the order a consumer hits them

### G1. A deploy manifest enumerates *stacks*, not plugins

`deploy-manifest.yaml` is the deploy workflow's input, and the workflow deploys stacks. A real
platform's manifest routinely carries entries that are not Reventless plugins at all and can never
have a `pluginStructure`:

- an **SdkService** stack — resolvers, middleware and event hooks behind `SdkService_Handler`, with
  no `Plugin.Make` anywhere in it;
- a **static SPA** stack — S3 + CloudFront, no AppSync surface;
- a **standalone Lambda** stack — an ingester wired to an S3 notification.

Stage 3 read the manifest as "it already enumerates every plugin path". It enumerates every
*deployable*, which is a strictly larger set. The generator treats a missing manifest as an author
error ("build the plugin first") when for these entries it is a category error: there is nothing to
build that would produce one.

**Fix:** distinguish *absent because unbuilt* from *absent because not a plugin*, and do not exit on
the second. The cheapest signal that needs no new hand-written spelling is the package itself — a
stack with no dependency on a package exporting a plugin composition cannot contribute capabilities.
An explicit `kind:` on the manifest entry is the alternative, and is worse: it is a second statement
of a fact the package graph already carries, which is the exact cost Stage 3 exists to remove.

### G2. A deploy root that wraps a published composition package has no manifest under it

The framework's intended shape for a consuming repo is a thin `-aws` root over a published plugin:

```rescript
module Make = (Platform: ReventlessInfra.Platform.T with type api = … and type role = …) => {
  module Composition = CatalogPlugin.Plugin.Make(Platform)
  let make = () => Composition.make()
}
```

There is no `generate` script on that root — nothing is generated, the composition is *installed* —
and no `src/capabilities.json`, because the manifest ships inside the dependency, at
`node_modules/<pkg>/src/capabilities.json`. Both resolution paths miss it.

This is the more important gap of the three, because it is the shape the framework recommends. The
manifest is *present and correct*; the generator simply cannot find it.

**Fix:** resolve through the dependency graph. The root's `package.json` names the composition
package; resolving that package and reading its `src/capabilities.json` uses the same record the
build already relies on. It also composes with G1's fix: a stack that depends on no plugin package
contributes nothing, and one that does contributes exactly that package's manifest.

### G3. `emit-capabilities` hardcodes `Plugin.res.mjs`

The bin takes a `<srcDir>` and imports `<srcDir>/Plugin.res.mjs`. That is the filename
`generate-plugin` emits, so it holds for generated composition roots and for nothing else. A plugin
whose composition module is hand-written — and therefore named after the plugin, which is the
natural thing to do — cannot emit a manifest at all, even though its `Make` produces a
`pluginStructure` exactly like a generated one's.

**Fix:** accept the module path (or module name) as an optional second argument, defaulting to
`Plugin.res.mjs` so every current caller is unaffected. The reflection strategy is unchanged; only
which file gets imported is.

## Why this is worth doing rather than documenting

Stage 3 removed a hand-written line whose two halves could silently disagree. A platform that cannot
run the generator keeps that line, and keeps the failure mode: a capability's `plugin` and the
plugin's registered name stay independent spellings, and a case slip between them provisions a store,
exports its endpoint under a key nothing queries, and lets the upload input fall back to the legacy
service — writing to the wrong bucket with a 2xx and a plausible ref.

The `deployPlugin` coverage assertion makes that loud rather than silent, which is real and is why
this is schedulable rather than urgent. But "loud at deploy time" is a weaker guarantee than "cannot
be written wrong", and the platforms that most need the stronger one are precisely the ones assembled
from published packages, where the plugin's registered name is defined in a repo the platform author
does not edit.

## Steps

1. **G3 first — it is the smallest and unblocks the others' testing.** Optional module argument on
   `emit-capabilities`, default unchanged. Verify: a plugin whose composition root is not named
   `Plugin.res` emits a manifest byte-identical to one that is.

   **Done.** `emit-capabilities <srcDir> [<compositionModule>]`. A bare module name (`Catalog`)
   resolves inside `<srcDir>`, a path (`./src/Catalog.res.mjs`) from the working directory, and the
   `.res.mjs` suffix is appended when absent. Verified on the hybrid catalog with the composition
   root copied to `Catalog.res.mjs`: bare-name form, path form and the unchanged default all emit
   byte-identical manifests (md5-checked against the committed file).

   **The bin was also moved into ReScript, which is where this argument handling belongs.** It had
   been a hand-written `.mjs` justified in its own header as "untyped by necessity: a dynamically
   imported module cannot be functor-applied from ReScript". That is not true, and
   `ReventlessGwt.LocalHost` — which reflects the domain graph exactly this way — had already
   disproved it: the imported module's exports are declared as object types
   (`{"Make": platform => builtPlugin}`), so `pluginStructure` arrives as
   `Reventless.Plugin.pluginStructure` and the untyped surface is two `import()` calls. The platform
   is imported rather than applied as a functor for a real reason worth keeping written down: a
   composition root's `Make` expects the platform *value*, and a ReScript module is not one —
   importing both sides puts them on the same footing without `Obj.magic`. Logic now lives in
   `ReventlessLocal.EmitCapabilities`; `emit-capabilities.mjs` is a three-line bin shim, the same
   shape as `run-platform-generator.mjs`.

2. **G2 — dependency-graph resolution** in `PlatformGenerator.manifestPathFor`, tried after the two
   existing paths so no current caller changes behaviour. Verify: a root whose only plugin content is
   a dependency yields that dependency's manifest, and regenerating is byte-identical.

   **Done**, though not in `manifestPathFor` — see step 4 for where it went. Node's directory
   resolution is walked directly (`<dir>/node_modules/<name>`, then each parent's) rather than
   binding `require.resolve`: a package's entry point may be anywhere, and it is
   `src/capabilities.json` that is wanted, not the module the package exports. Verified on a
   synthetic consumer whose `catalog-aws` root has no `generate` script and no `src/` — only a
   dependency on a composition package under `node_modules/@acme/catalog` — which previously exited
   1 and now resolves that package's manifest and regenerates byte-identically.

3. **G1 — non-plugin entries contribute nothing instead of exiting.** Verify: a manifest mixing
   plugin and non-plugin stacks generates the union of the plugins' capabilities and does not fail;
   a plugin whose manifest is genuinely missing *still* fails, with the existing message.

   **Done.** The evidence separating the two cases is **a package whose `scripts` run
   `emit-capabilities`** — the fact stated once, by the package that owns it, and already present in
   every plugin package. (`reventless-local` exposes the bin under `bin`, not `scripts`, so
   *providing* the bin is correctly not evidence of *being* a plugin; a test pins this.) Verified on
   the same synthetic consumer, whose manifest also lists an SdkService stack and a static SPA: both
   are skipped with a logged line, the plugin's capabilities are generated, exit 0. Deleting the
   installed plugin's manifest still exits 1 with the original message, now carrying the evidence and
   the path it looked in.

   One deliberate addition of scope: a manifest entry pointing at a **directory that does not exist**
   is now a hard failure. Without it, G1's fix would read a typo'd path as "not a plugin" and skip it
   silently — the exact substitution the risks table warns about, arriving through the front door.

4. Extend `PlatformCodegenTest` with the mixed-manifest case, and state the resolution order in the
   generator's own comment — three fallbacks in sequence is exactly the kind of thing that gets a
   fourth added blindly.

   **Done, and the resolution moved out of `PlatformGenerator` to do it.** Four arms with an
   evidence distinction is no longer a nested `if` inside a bin whose top level calls
   `process.exit` — and a bin's top level cannot be imported by a test, so as written it was
   unpinnable. Resolution now lives in **`PlatformManifests`**, which owns the ordered comment and
   takes its file system as a record, so the arms are tested against in-memory layouts (local,
   hoisted, scoped `node_modules`) with no fixture tree. `PlatformManifestsTest` pins each arm both
   ways — what it resolves and what it refuses to — and `PlatformCodegenTest` gains the mixed-manifest
   render case. Which arm resolved each manifest is logged per plugin, per the risks table.

## What this does not do

- **It does not change what a capability is, or how one is declared.** `@storageRef` on a field
  remains the single requirement; this is entirely about finding the manifests that already exist.
- **It does not remove the `deployPlugin` assertion.** Wider generator reach makes the two spellings
  agree in more places; it still cannot catch a platform deployed before a regenerate.
- **It does not add a manifest format or a per-stack `kind:` field.** Both would restate something
  the package graph already knows.

## Risks

| Risk | Mitigation |
|---|---|
| **G1's fix hides a genuinely missing manifest**, so a platform silently deprovisions a store because the plugin that declared it was skipped rather than read. | The two cases must be distinguished by evidence, not by fallthrough: *depends on a plugin package but has no manifest* stays a hard failure; *depends on no plugin package* contributes nothing. Step 3's second verification pins exactly this. |
| Dependency-graph resolution picks the wrong package on a root that depends on several plugin packages. | Union them rather than choosing — a root deploying two plugins legitimately requires both. Dedup by `(plugin, store)` already handles the overlap. |
| A resolution order of three fallbacks becomes untraceable when one silently wins. | Log which path resolved each manifest. The generator's output is committed and reviewed; which file it came from should not need reconstruction. |
