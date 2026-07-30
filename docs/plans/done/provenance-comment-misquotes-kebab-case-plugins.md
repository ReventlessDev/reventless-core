# Plan: the generated provenance comment misquotes the annotation it names

**Date:** 2026-07-30
**Status:** **Complete (2026-07-30).** Reproduced first against the compiled `PlatformCodegen`, then
fixed; each step's outcome is recorded inline. Found by driving a `@storageRef` end to end through
`generate-platform` on a platform whose plugin names are kebab-case.
**Repos:** `reventless-core` only.
**Builds on:** [platform-capability-provisioning-stage-3.md](./done/platform-capability-provisioning-stage-3.md)
(D3, the provenance comment) and
[generate-platform-beyond-the-example-topology.md](./done/generate-platform-beyond-the-example-topology.md).

## The defect

`PlatformCodegen.annotationStore` decides whether a provenance comment quotes a store qualified or
bare, and its own header states the intent:

> The provenance comment quotes the annotation **as its author wrote it**: a store declared by its
> own plugin is unqualified, a foreign store keeps the qualified form.

The test for "its own plugin" is a case-insensitive comparison between the key's prefix (the
*registered* plugin name) and the manifest's plugin name (the *deploy-manifest entry* name):

```rescript
| Some((keyPlugin, store)) if keyPlugin->String.toLowerCase == pluginName->String.toLowerCase => store
```

Case is not the only way those two spellings legitimately differ. A deploy manifest naming its
stacks in kebab-case — the ordinary convention for a directory and a stack name — against a plugin
registered in PascalCase produces:

| entry name | registered name | lowercased comparison | comment emitted |
|---|---|---|---|
| `catalog` | `Catalog` | `catalog == catalog` ✓ | `@storageRef("productImages")` — correct |
| `platform-inspector` | `PlatformInspector` | `platform-inspector ≠ platforminspector` ✗ | `@storageRef("PlatformInspector.inspectorSnapshots")` — **wrong** |

The source in that second row reads `@storageRef("inspectorSnapshots")`. The comment claims a string
that appears nowhere.

Observed, not reasoned about: a plugin whose sole `@storageRef` is on a `SyncAlarmState` command
field generated

```rescript
// platform-inspector: SyncAlarmState.urn @storageRef("PlatformInspector.inspectorSnapshots")
ObjectStore({plugin: "PlatformInspector", store: "inspectorSnapshots"}),
```

The examples in this repo cannot show it, because every one of them names its stacks with the
lowercased registered name.

## Why it is worth fixing rather than tolerating

The comment is not decoration — D3 introduced it for one job, and this is exactly that job:

> When a capability disappears because a field was renamed, the diff has to say which field.

A reader who follows a removed capability back to its source greps the string the comment gives them
and finds nothing. That is worse than no comment, because a wrong lead reads as "the annotation was
already deleted" rather than "look harder". It fails precisely in the situation it exists for, and it
fails silently — nothing about the generated file looks wrong.

The blast radius is small (a comment), which is an argument about priority, not about correctness.

## The fix

**The emitting plugin already knows the answer and is throwing it away.** At `emit-capabilities`
time the plugin is reflecting its own `pluginStructure`: a store whose key prefix is its own
registered name *is* its own, and the annotation text is the bare store. No comparison, no
normalisation, no guess. The generator is the wrong layer to ask, because it only ever sees two
names that were never required to match.

So: **carry the annotation's own spelling in the manifest**, per declaring site, and have
`PlatformCodegen` quote it verbatim.

That also makes the rendered comment robust against the case D3 explicitly wanted to preserve — a
*foreign* store keeps its qualified form — without inferring which case applies from names that do
not carry the fact.

The cheaper local patch (normalise separators before comparing, so `platform-inspector` matches
`PlatformInspector`) is not recommended: it trades one guess for a slightly better guess, and the
next naming convention that does not round-trip reintroduces it. It is the same shape as the
two-independent-spellings problem Stage 3 exists to remove, and it would be odd to fix that at the
capability list and keep it in the comment describing it.

## Steps

1. `CapabilityManifest`'s declaring site gains the annotation text as written (alongside `component`
   and `field`). `Plugin_Structure`'s store walk already visits the declaration; the bare-vs-qualified
   spelling is available there, where the owning plugin is unambiguous.

   **Done.** `Plugin.requiredStoreDeclaration` gained `annotation: string`, filled in
   `Plugin_Structure.storesFromProperties` straight off the semantic payload — `target.plugin` is
   `None` exactly when the field left the store unqualified, so the value is the source text rather
   than a reconstruction of it.

   **`CapabilityManifest.provenance.annotation` is optional, and deliberately.** The manifest is a
   *file on disk* that `generate-platform` parses with `S.parseOrThrow`; a required field would make
   every manifest emitted before this change fail to parse, and the generator reports that as
   "could not parse … as a capability manifest" — which reads as corruption, not staleness. Optional,
   a stale manifest still resolves and the renderer simply makes no claim about source it cannot see.
   `pluginStructure` is the opposite case — derived fresh at runtime, never stale — so `annotation`
   is required there.

2. `PlatformCodegen.annotationStore` goes away; the renderer quotes the site's recorded text.
   `PlatformCodegenTest` gains a kebab-case-entry-name case that currently renders the wrong string.

   **Done.** `annotationStore` is deleted; `splitKey` stays, since the `ObjectStore({plugin, store})`
   line still needs it — and that line was always correct, which is why the capability list never
   moved. Two tests added: the kebab-case case (which asserts both that the right string is present
   *and* that the qualified one is absent), and the no-recorded-annotation case.

3. Re-emit the example manifests. Expect **no change** to any of them — every example's names
   round-trip today, which is why this was invisible — so a diff here means step 1 changed more than
   the spelling.

   **Done, and this step as written was wrong.** Step 1 adds a per-site field, so every non-empty
   manifest *necessarily* changes — as this plan's own risks table says two sections down. The
   invariant worth checking is the one about the **rendered comments**, and it holds: after
   re-emitting all six manifests, `generate-platform` on all three examples produced
   `PlatformCapabilities.res` **byte-identical** to the committed files. Two manifests gained
   `annotation` keys (aggregates catalog, hybrid catalog); the other four declare nothing and are
   unchanged.

   Worth knowing: the root `pnpm run build` is a chain of `rescript build` invocations and does
   **not** run the plugin packages' `postbuild: emit-capabilities`. Re-emitting is a separate,
   explicit step.

## What this does not do

- **It does not change the capability list itself.** The `ObjectStore({plugin, store})` entries were
  correct throughout; `plugin` comes from the manifest key, not from this comparison. Only the
  comment above them is affected, and no deployment ever read it.
- **It does not change which schemas the store walk reads.** Commands, produced events and state
  schemas remain in scope; consumed events remain out, which is right — a consumed event is another
  plugin's produced event, and its store is that plugin's requirement, not the consumer's.

## Risks

| Risk | Mitigation |
|---|---|
| Adding a field to `CapabilityManifest` changes the emitted JSON, and the manifests are committed files that a stale-check may compare byte-wise. | Every plugin's manifest is re-emitted by its own ordinary build, so the churn lands once, as a reviewable diff. Step 3's expectation (no *comment* change on the examples) is what separates an intended re-emit from an unintended semantic change. |
| The recorded annotation text drifts from the key if a future emitter writes them independently. | Derive both from the one walk, the same constraint Stage 3's step 1 imposed on `requiredStores` and its provenance triples — and for the same reason. |

## One consequence to know

`requiredStoreDeclaration` gained a **required** field, and `pluginStructure` is persisted. Plugin
definitions written before this change no longer decode and must be re-emitted — the same
alpha-wipe/reconnect that `requiredStores` and `requiredStoreDeclarations` each needed when they
landed, and for the identical reason. Nothing in the capability list or the deployed behaviour
changes; the reconnect is purely to re-persist definitions in the new shape.
