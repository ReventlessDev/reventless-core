# Plan: platform capability provisioning — Stage 3 (inference and generation)

**Date:** 2026-07-29
**Status:** Not started. Written against the shipped Stage 2 + follow-on, not against the analysis
as originally drafted — both post-date it, and one of Stage 3's four components has already landed.
**Repos:** `reventless-core` only.
**Analysis:** [platform-main-capability-provisioning.md](../analysis/platform-main-capability-provisioning.md) §6 Option B, §7 Stage 3.
**Builds on:** [platform-capability-provisioning-stage-2.md](./done/platform-capability-provisioning-stage-2.md)
and [declared-object-stores-without-host-ui-bundle.md](./declared-object-stores-without-host-ui-bundle.md).

## What is left, precisely

The declaration side is finished. `@storageRef("productImages")` on a field *is* the requirement, and
`Plugin_Structure.requiredStores` derives `Catalog.productImages` from it with no human involvement.

**Exactly one manual act remains**, and this stage exists to remove it:

```rescript
let capabilities: array<ReventlessInfra.Platform.capability> = [
  ObjectStore({plugin: "Catalog", store: "productImages"}),
]
```

That line is hand-typed, and nothing derives it from the declaration it restates. The two halves of
one fact — the capability's `plugin` and the plugin's registered name — have independent spellings,
so they can disagree. That is not a hypothetical: they *did* disagree, and the symptoms were entirely
silent. The store was provisioned, its endpoint exported under a key nothing queried, and the upload
input fell back to the legacy service and wrote to the wrong bucket with a 2xx and a plausible ref.

Stage 3's four components, per §7:

| Component | State |
|---|---|
| `deployPlugin` coverage assertion | **Done.** Shipped as the follow-on to declared-store serving. |
| `capabilities.json` per plugin | **Done — step 1.** See the step for what was built and learned. |
| `Capability_Inference` | Not started — step 2 |
| `generate-platform` | Not started — step 3, and **narrower than the analysis proposed** |

Because the assertion already exists, the failure mode is loud today even while the list stays
hand-written. That is what makes this stage schedulable rather than urgent, and it should be built
calmly.

## Three decisions to take before writing code

### D1. `capabilities.json` stays JSON. The split is principled, not accidental.

The repo already carries both formats, and the rule sorting them is real but has never been written
down — which is the actual defect, since the next artifact has to guess.

| Format | Who authors it | Who reads it | Examples |
|---|---|---|---|
| **YAML** | a human, by hand | CI, deploy tooling, an operator | `deploy-manifest.yaml`, `users.yaml`, `Pulumi.<stack>.yaml` |
| **JSON** | a build step, mechanically | a program — generator, runtime, browser | `*.model.json`, `ui-hints.json`, `plugin.json` |

**The rule: hand-authored config is YAML; machine-emitted artifacts are JSON.** It follows from what
each format is good at rather than from taste.

- **YAML earns its place on human-edited files because of comments.** `deploy-manifest.yaml` opens
  with two comment lines explaining what it drives; JSON cannot carry them, and a manifest whose
  purpose is undocumented at the point of editing is worse.
- **JSON earns its place on emitted files because it has one serialization.** YAML's implicit typing
  is a liability for generated content — `NO` is a boolean, `1.0` may be a string or a float,
  indentation changes are semantic — and generated files are read by diff far more often than by a
  human. A generator that must defensively quote its own output is a generator with a bug waiting.
- **`ui-hints.json` settles the runtime case on its own**: it is fetched by a browser. Shipping a
  YAML parser into the shell bundle to read a config file would be dead weight.

So `capabilities.json` is JSON, and it is JSON *for a reason that generalises*: it is emitted by a
build step and consumed by a generator, never edited. `deploy-manifest.yaml` stays YAML for the
mirror-image reason. **Write the rule down** — see step 4 — so this stops being re-litigated per
artifact.

The one thing worth changing is neither format: it is that `*.model.json` sidecars are gated behind
`REVENTLESS_EMIT_SIDECAR=1` and are already stale (27 `@@reventless.spec` files against 26 sidecars
in the example tree, with the most recently added slice missing). They are a reverse-codegen
convenience, not a build invariant, and step 1 must not depend on them.

### D2. `Main.res` keeps its name. The concern behind the question is real; the rename is the wrong fix.

Renaming the platform root to `Platform.res` is actively hazardous here, for a reason specific to
this codebase rather than to taste:

**These packages have no `namespace` in `rescript.json`, so module names are flat.** A file
`Platform.res` defines a top-level module `Platform` — in a package whose root already contains
`module Platform = ReventlessAws.Platform.Make()`, and where `ReventlessAws.Platform` is itself a
module of that name. The binding would nest inside a module of the same name and shadow it, and any
sibling file referring to `Platform` would resolve to the file rather than the functor instance.
That is a confusing failure with no upside.

Two further costs: `Main.res` is the declared entry point (`Pulumi.yaml`'s `main: src/Main.res.mjs`),
so a rename touches every root's `Pulumi.yaml`; and *every* deploy root is `Main.res` today — plugin
roots and local roots included — so renaming only the platform's creates a special case where a
uniform convention exists.

**The real concern is different and worth solving:** a generated file should not be
indistinguishable from a hand-written one. The repo already has the answer — plugin roots and
`Plugin.res` carry `// AUTO-GENERATED — do not edit. Run \`npm run generate\` to update.` — and D3
makes it moot for most of the file anyway.

### D3. Generate a capability *file*, not the whole root.

The analysis proposes emitting `platform-aws/src/Main.res` entire, as `// AUTO-GENERATED`. Checked
against what platform roots actually contain, that is too coarse. A real root carries deploy-time
observability registration, `DeployBootstrap` calls, hand-written capability handles, stack
references, and output re-exports — hand-written concerns that the generator would have to be able
to express, and would fight every root that does something the generator has not anticipated.

**Emit only the derived list, into its own file:**

```rescript
// AUTO-GENERATED — do not edit. Run `pnpm run generate:platform` to update.
// catalog: ChangeProductImage.imageUrl @storageRef("productImages")
let capabilities: array<ReventlessInfra.Platform.capability> = [
  ObjectStore({plugin: "Catalog", store: "productImages"}),
]
```

The root then reads `~capabilities=PlatformCapabilities.capabilities` and stays hand-written.

This keeps every property §6 wanted from Option B — deterministic, zero runtime coupling, and a
requirement change landing as a **reviewable diff in a committed file**, which is what makes the
silent-deprovisioning risk manageable — while making the diff *smaller and entirely about
capabilities*. It also sidesteps D2 completely: the generated file is not the entry point, so it can
be named for what it is.

The provenance comment is not decoration. When a capability disappears because a field was renamed,
the diff has to say which field.

## Steps

### 1. Emit `capabilities.json` from the normal plugin build

One file per plugin, beside `Plugin.res`, listing each requirement with its instance key and
provenance (`Declared(component, field)`).

Two constraints, both learned rather than assumed:

- **Ungated.** It must come from a step of the ordinary build, not from an env-var-gated one. The
  sidecar precedent is the counter-example to copy nothing from.
- **Derived from the same code path as `requiredStores`.** `Plugin_Structure` already computes the
  qualified `{plugin}.{store}` set from the field declarations. The manifest must come from *that*,
  not from a second scan — otherwise Stage 3 reintroduces at build time exactly the two-independent-
  spellings problem it exists to remove.

**Verify:** a plugin with no `@storageRef` emits an empty list, not a missing file. Renaming a
declaring field changes the manifest. The manifest's keys are byte-identical to the plugin's
`requiredStores` at runtime — assert this in a test, since it is the whole contract.

**Done (2026-07-30).** How the constraint resolved in practice: `requiredStores` is computed at
runtime by `Plugin_Structure` from the compiled sury schemas, not at generation time — so "the same
code path" meant *reflecting the compiled plugin*, not extending `generate-plugin` (which is a
source scanner, i.e. exactly the second scan this step forbids). The pieces:

- `Plugin_Structure`'s store walk now keeps each declaration site as a
  `{store, component, field}` triple (`pluginStructure.requiredStoreDeclarations`, js_nullable like
  its siblings), and `requiredStores` is **derived from those triples** — one walk, so provenance
  and key set cannot disagree. Identical triples collapse (one store on a command and event field
  of the same component is one site).
- `Reventless.CapabilityManifest` (spec) renders the manifest *from* `requiredStores` itself, so
  key-set byte-identity holds by construction; `PluginStructureTest` asserts it anyway, plus
  provenance, the empty-list case, and the exact rendered bytes.
- `emit-capabilities` (bin in `reventless-local`) dynamically imports the plugin's compiled
  `Plugin.res.mjs`, applies it to the local platform — the same reflect-don't-parse strategy as the
  domain graph — and writes `src/capabilities.json`. Wired as **`postbuild`** in all six
  composition plugin packages (ungated, sibling of the `prebuild` generate step). The `-aws` roots
  delegate to the composition packages, so the manifest lives beside the composition `Plugin.res`.
- Verified live: hybrid/aggregates catalogs emit `Catalog.productImages` with three/two declaring
  sites; the four store-less plugins emit `{"capabilities": []}`; re-emitting is byte-identical
  (md5-checked).

One consequence to know: the new pluginStructure field follows the js_nullable pattern, which is
present-required on decode — plugin definitions persisted *before* this field existed no longer
decode and must be re-emitted (the usual alpha-wipe/reconnect, same as when `requiredStores` itself
landed).

### 2. `Capability_Inference` — declaration-first, heuristics as warnings

Declarations are authoritative. Heuristic matches (a field named `imageUrl` with no `@storageRef`)
are reported as warnings naming the field and the annotation that would settle it, and **never
provision anything**. §5.1's ordering: guessing is a poor basis for creating and destroying
infrastructure.

**Verify:** a heuristic-only match produces a warning and no manifest entry.

### 3. `generate-platform` — union the manifests, emit the capability file

A CLI sibling to `generate-plugin`. Reads `deploy-manifest.yaml` for the plugin list (it already
enumerates every plugin path), unions their `capabilities.json`, and writes the committed
`PlatformCapabilities.res` per D3. Dedup by `(plugin, store)` — that pair is a store's identity, and
many fields legitimately name one store.

**Verify:** regenerating with no source change is a no-op (byte-identical output, so the committed
file does not churn). Removing the last declaring field removes the entry, and the diff shows it.
Running it on a platform whose plugins declare nothing produces an empty list, and `deployPlatform`
provisions nothing.

### 4. Write the format rule down

D1 as a short section in the analysis, next to the manifest discussion. One paragraph and the table.
The cost of not having it is that every future artifact re-argues it, and the arguments are not
obvious from either format in isolation.

## What this does not do

- **It does not remove the `deployPlugin` assertion.** Generation makes the two spellings agree by
  construction; the assertion still catches a platform deployed before a regenerate, which is an
  ordering failure generation cannot prevent. Keep both — the `NotAdopted` arm in particular stays
  meaningful for platforms that have not taken this stage.
- **It does not touch the layout, protection or serving decisions.** Those are settled and tested in
  `Util_StoreLayout`; Stage 3 changes only where the *list* comes from.
- **It does not extend the capability catalogue.** `Geocoding` and the rest of Stage 4's providers
  are out of scope; this stage must work for exactly the two that exist.

## Risks

| Risk | Mitigation |
|---|---|
| **The generated file drifts from the plugins because nobody reran the generator**, and the platform deploys with a stale list. | Precisely what the `deployPlugin` assertion already catches, and the reason step 3 does not remove it. Consider failing the build when regeneration would change the committed file — the same shape as a lockfile check. |
| **Generation makes silent deprovisioning easier**: renaming a field now removes a bucket with live objects, with no human in the loop. | The committed diff is the review gate, which is why D3 keeps it small and why the provenance comment names the causing field. Provisioned stores are `protect: true` by default, so the destroy is refused rather than performed. |
| `capabilities.json` derived by a second scan rather than from `Plugin_Structure`, reintroducing two sources for one fact. | Step 1's second constraint, and the byte-identical assertion in its verification. This is the failure this whole stage exists to remove; reintroducing it at build time would be an unusually bitter outcome. |
| **Core's own unit tests do not run in its default suite.** | Run `jest --selectProjects reventless-core` when judging this change; a green default suite is not evidence. |
| A push to `alpha` publishes *and* deploys, with no review step between preview and apply. | Know it before pushing; the generated-file diff is the review that replaces it. |
