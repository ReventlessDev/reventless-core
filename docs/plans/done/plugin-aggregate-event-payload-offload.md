# Plan: a general client-driven `@offload` field primitive, first applied to plugin payloads

**Date:** 2026-08-02 (shipped 2026-08-03; `@offload` ppx shorthand + per-field threshold added 2026-08-03)
**Status:** ✅ **DONE** — the `@offload` primitive (validated live on `alpha`), plus the ppx shorthand
and end-to-end per-field threshold (this session, tested). **Republished + released** (`alpha.61` ppx
binaries + `reventless-spec@alpha.97`, pin kept), and offloading **re-verified live** post-deploy —
see "Republished + released". The shorthand is **not** usable in `Plugin.res` (needs `@@reventless.spec`;
see below). The only follow-up is orthogonal: the
Sury `alpha.4 → rc.0` bump (its own session, also tracked in memory). Moving to `done/`.

## Current state (read this first if resuming)

The full round-trip works on live `alpha` and is runtime-validated: `VersionConnected` events
carry `{$offload}` refs (small + content-addressed/deduped); the producer writes a `BucketObject`
to a dedicated `reventless-offload-*` bucket at deploy time; the ComponentDefinitions Lambda
resolves refs from S3 (scoped GET IAM) and returns real component counts (verified via
`aws lambda invoke PlatformUIDefinitionsLambda-*` → Catalog 3 SVS/9 SCS, Ordering 1/1/1/4, no leak).

**Shipped (pushed to alpha):** `Offload` primitive + untagged `S.union` codec + `getInline`/
`toJson`/`prepare`/`resolve`/`cachedFetch` (`reventless/spec`); event field retype
(`pluginDefinition.structure`/`apiSchemaFragment` → `Offload.payload`); core producer hook seam
(`Plugin_Helpers.offloadHook` + `Plugin_Builder`); AWS activation (offload bucket + export,
producer hook via Node sha256 `BucketObject`, S3 `GetObject→string` binding, ComponentDefinitions
resolver + GET IAM).

**Design correction learned the hard way (critical for anyone extending this):** the read-model
DynamoDB write path marshals the **raw ReScript value** (DocumentClient) — it does NOT sury-encode
via `@s.matches`. So a **variant** read-model field (`Offload.payload`) persists as ReScript's
runtime `{TAG,_0}` shape and breaks any raw-JSON reader (the ComponentDefinitions Lambda → AutoUI
component graph empty). **Rule: read-model fields must be plain records/scalars/`JSON.t`, never
variants.** Fix applied: `PluginsReadModelSpec.structure`/`apiSchemaFragment` are `option<JSON.t>`
and `PluginsProjection` writes the untagged codec JSON via `Offload.toJson` (bare, or `{$offload}`);
the resolver detects `$offload` (resolve) / passes bare through — **no `{TAG,_0}` tolerance**.
Settled design: **offloading lives in the immutable EVENT (size/dedup win); the read model is a
plain untagged JSON blob, resolved lazily by the client that needs it.**
**Meta-lesson: a green deploy ≠ working runtime — always run the runtime query (invoke the Lambda /
query the resolver), not just "did it deploy".**

One-time data repair (already done, not migration code — alpha example data): the 2 pre-fix rows
(`{TAG,_0}`) were rewritten to `{$offload}` via a throwaway DocumentClient script.

## Done since — `@offload` ppx shorthand (2026-08-03)

`packages/reventless-ppx/src/ppx/OffloadInference.ml` (new) + wired into `ReventlessPpx.ml` right
after the `StorageRefInference` line. Modelled on `StorageRefInference.ml`. Surface:

```
@offload("store") structure: option<pluginStructure>          // → optionSchema
@offload("plugin.store") structure: pluginStructure           // → forStore, cross-plugin
@offload({store: "store"}) structure: option<pluginStructure> // record form
```

It rewrites the field type `X` / `option<X>` → `Reventless.Offload.payload<X>` /
`option<Reventless.Offload.payload<X>>`, derives the inner schema by sury convention (`t` →
`schema`, else `<name>Schema`, preserving a module prefix), and emits
`@s.matches(Reventless.Offload.forStore/optionSchema(~plugin?, ~store, <innerSchema>))` — byte-for-byte
the hand-written first-consumer form, just fully qualified. Idempotent if the field is already
`Offload.payload<X>`; a manual `@s.matches` wins (marker stripped, schema left alone).

**Threshold precedence chain — now wired end-to-end** (per the plan's "Threshold precedence chain"
section). `Semantic.storeTarget` gained `threshold: option<int>` (`@storageRef` passes `None`);
`Offload.forStore`/`optionSchema` take `~threshold=?` and mark it; the ppx record form
`@offload({store, threshold: N})` emits `~threshold=N` (the string form carries none). Readers:
`Offload.getThreshold(schema)` (raw per-field value) and `Offload.effectiveThreshold(schema,
~platformDefault?, ())` resolving per-field marker → platform default → `Offload.defaultThreshold`
(8 KB). A client reads the field schema, calls `effectiveThreshold`, and passes the result to
`Offload.prepare(~threshold)` — `prepare` stays threshold-explicit because it holds the *value*
schema, not the field schema that carries the marker. Level 2's `MakeWithConfig.offloadThreshold`
is represented as the `~platformDefault` argument (a client supplies its platform config value);
adding an actual `offloadThreshold` field to `MakeWithConfig` is deferred until a client reads
platform config, to avoid an unused config knob. The plugin producer still offloads unconditionally
(Pulumi-Output constraint), so on the plugin path the threshold is declarative until a general
`prepare`-driven client (browser/seed/Node) adopts it. Non-derivable inner types (array, type
params) raise pointing at the explicit-helper escape hatch.

**The shorthand is NOT usable in `Plugin.res` — it needs a `@@reventless.spec` file.** `OffloadInference`
(like `StorageRefInference`) runs *only* inside the ppx's spec-mode branch, i.e. on files carrying a
file-level `@@reventless.*` attribute. `Plugin.res` is a hand-written framework module with none, so
`@offload` there is silently ignored and the field degrades to a plain `S.option(...)` — a
wire-incompatible loss of the offload codec. **Proven empirically** (2026-08-03): with the `alpha.61`
`@offload`-capable ppx materialized, `@offload("pluginStructures") structure: option<pluginStructure>`
still compiled to `s.m(S.option(pluginStructureSchema))`. An earlier note here wrongly claimed it *was*
usable — that test used the manual `@s.matches(Reventless.Offload.optionSchema(...))` form, a sury
attribute any ppx passes through, which does **not** exercise the `@offload` marker. (`Reventless.Offload`
*does* resolve in-namespace, but that's irrelevant when the pass never runs.) So `Plugin.res` stays on
the explicit bare-`Offload` helper as a **requirement**, not a choice. The shorthand's real consumers
are `@@reventless.spec` files (app/example plugin specs); there is no natural in-repo consumer yet, so
this is the capability + its test.

Verified: isolated `bsc -dsource` on all forms + every error/edge case (incl. the record threshold
form → `~threshold:N`, string form omits it); compile-based `test/run.sh` fixture (`OffloadHost.res`
→ `optionSchema`/`forStore`/`blobSchema`/`"blobs"`/`4096`, marker stripped) — **227 passed**; spec
`OffloadTest` threshold cases (`getThreshold`, `effectiveThreshold` precedence, declaration →
`effectiveThreshold` → `prepare` split) — spec suite **329 passed**; frozen `PluginLifecycleCorpusTest`
+ `MessageTest` still green (the `storeTarget` change is metadata-only, not on the wire).

Docs (both surfaces, previously undocumented — `@storageRef` was missing too, added alongside):
`.claude/rules/app-developer.md` gained a "Semantic field markers" subsection; the docs site's
`packages/doc/docs-app/reventless-ppx.md` gained a `@storageRef`/`@offload` section + a
"What the PPX replaces" row (cross-instance link `/framework/ppx-binary-management`).

**Republished + released (pushed 2026-08-03).** Commits `3d5e3b5da` (ppx source + threshold) and
`0bdd200df` (per-platform scaffolds → `alpha.61`) pushed to `alpha`; `publish-ppx.yml` published
`reventless-ppx-linux-x64` + `-darwin-arm64` at **`alpha.61`** (its `Test PPX` job red on an apt/sudo
infra flake — the two publish jobs succeeded), and the lerna Release train bumped main
`@reventlessdev/reventless-ppx` to `alpha.61` and published `reventless-spec@3.0.0-alpha.97`. The
`alpha.61` **pin was kept** (Phase 2): main's `optionalDependencies` range bumped `^alpha.58` →
`^alpha.61` + lockfile refreshed (clean 20-line diff) so `--frozen-lockfile` installs resolve the
`@offload`-capable binary. Behavior-identical for all committed code (nothing uses `@offload`).

**Live runtime re-verified post-deploy (2026-08-03).** The `Deploy Online Shop Hybrid` deploy of
`reventless-spec@alpha.97` went green, and invoking the ComponentDefinitions Lambda on the **current**
Plugins read-model table (`Plugins-a115fd5`, written by the post-deploy Heartbeat at plugin
`alpha.180`, storing `{$offload}`) resolves refs from S3 to real components matching the original
validation exactly — **Catalog 3 SVS/9 SCS, Ordering 1/1/1/4, no `$offload`/`{TAG,_0}` leak**. So the
metadata-only `storeTarget` change is confirmed non-regressive on live. **Separate pre-existing issue
(NOT from this session):** a second Plugins table (`Plugins-1b3ba55`, a different API scope, read by a
second live Lambda) still holds *stale* `alpha.148` rows (written `00:01Z`, before the deploy) for
Ordering/Catalog/PlatformInspector in the old `{TAG,_0}` variant shape (pre-`Offload.toJson`-fix data
never re-written), so that Lambda returns empty components for them — deferred, needs a re-heartbeat of
those plugins in that scope or a one-time row repair.

## Remaining (optional — for a fresh session)

- **Sury `alpha.4 → rc.0` bump** — monorepo-wide (sury + sury-ppx lockstep, 9 packages), orthogonal;
  its own session.
- Preview loop for any further AWS work is verified working — exact command + env
  (`REVENTLESS_COGNITO_USER_POOL_ID=eu-west-1_CQTwafSeX AWS_REGION=eu-west-1`) is in the memory note.

## Problem

The plugin lifecycle aggregate's `VersionConnected` (and six sibling `pluginDefinition`-carrying
events) embeds the full plugin definition inline. Two fields dominate:

- `structure` — the plugin's component structure — **~74 KB**
- `apiSchemaFragment` — the plugin's API/SDL fragment (`{encoded, protocol}`) — **~32 KB**

Everything else is a few hundred bytes. Observed events run **107 KB**, the aggregate's event
log averages **~70 KB/event**, max over **130 KB**. Events are immutable, so each fat event costs
its size in the store, on every projection rebuild, through the change stream, and in any log of
the body. The payload is highly **repetitive across versions**: a re-registration with an
unchanged structure re-embeds ~106 KB byte-identical to a prior version. The log accumulates
many near-duplicate large blobs forever.

The plugin aggregate is the *first* place this bites, but the pain is not plugin-specific.

## Goal

Introduce a **general, client-driven `@offload` field primitive** and apply it to the two plugin
fields. A field's large value is uploaded to a content-addressed object store **by the client**
and carried in the command/event as a **reference**; small values stay **inline**. `VersionConnected`
shrinks from ~107 KB to **under 1 KB**, and identical structures across versions resolve to the
**same** object (free dedupe). Because the primitive is general, a second consumer is a
one-annotation opt-in.

## Findings that shaped this plan

Three facts from exploration determine the design:

1. **`Behavior.decide` is pure and synchronous** — `(state, command) => result<array<event>, error>`,
   no infra handle, not async (`reventless/core/src/Behavior.res:15`). It **cannot** perform an
   object-store PUT. There is also **no** command-side object-store write seam in the framework
   today (only the browser/seed presign→PUT upload path exists). Building a runtime command-side
   seam would be large framework plumbing.
2. **The plugin's two fields are produced at deploy time**, in `Plugin_Builder.res` (Pulumi
   `Output`-wrapped, lines 295-313 for `apiSchemaFragment`, 1047-1074 for `structure`), assembled
   into `pluginDefinition` (761-782), and reach the aggregate via the `Connect(pluginDefinition)`
   command. So the *client* that produces them is the **deploy-time Pulumi script**.
3. **The two fields are consumed in different environments** (read-side trace):
   - `apiSchemaFragment.encoded` is only ever decoded at **deploy time** (`aws/src/Platform.res`
     `preResolversSchemaHook` → `AppSync_Adapter.stitchStandaloneWithAwsDirectives`; the
     cross-plugin merge is AppSync **AUTO_MERGE**, not code). It is **never** read out of the read
     model and **never** decoded in a runtime Lambda.
   - `structure` *is* read out of the read model by a **runtime Lambda**,
     `Platform_ComponentDefinitions_Lambda_Ops.res:29-56` (filters `readModels`/`stateViewSlices`
     by visibility), plus local in-process (`local/src/Platform.res:1688/2240/879`) and Node
     tooling (`EmitCapabilities`/`CapabilityManifest`).

**Conclusion:** the client-driven model (client uploads, framework passes the ref through a pure
`decide`) is the right architecture — it needs **no** command-side seam. `decide` stays pure; the
event/command simply carry the reference. This is the `@storageRef` model, generalized with an
inline arm and a client helper.

## Design

### Model: client uploads, `decide` stays pure

A field marked `@offload` may carry either the inline value or a reference to bytes the **client**
already stored. The framework never PUTs on the command side. Producers use a framework helper
(below) to do the upload + reference construction easily; consumers use a resolve helper. This
mirrors `@storageRef` (`reventless/spec/src/semantic/StorageRef.res`) and reuses its provisioning
and semantic-marker machinery.

### The `payload<'a>` type + backward-compatible decode

```
type payload<'a> =
  | Inline('a)
  | Offloaded({store: string, key: string, hash: string, bytes: int})
```

The **decode must be backward-compatible with every event already in history**, which stores the
raw value inline with no wrapper. So the payload schema is an **untagged** codec, not sury's default
tagged union:

- if the JSON has the `Offloaded` shape (its distinctive `{store, key, hash, bytes}` keys), decode
  `Offloaded`;
- otherwise decode the whole JSON as `'a` → `Inline`.

This makes a legacy `structure: {readModels: […], …}` decode as `Inline({readModels: …})` with no
migration. Implemented as a sury custom schema in the `Offload` module. **A pre-change fixture from
the frozen corpus must decode green** (see Serialization).

### The `@offload` marker (ppx) + provisioning

Add `Semantic.Id.offload` alongside `storageRef` (`reventless/spec/src/semantic/Semantic.res:56`)
and an `Offload` module (`reventless/spec/src/semantic/Offload.res`) modelled on `StorageRef.res`.
The `@offload` field marker:

- declares the target store and carries an optional threshold: record form
  `@offload({store: "s", threshold: 16384})` and string shorthand `@offload("s")`
  (`"<plugin>.<store>"` for cross-plugin), mirroring how `@index` widens from `@index("n")` to
  `@index({…})`;
- attaches `Semantic.mark(~id=Semantic.Id.offload, ~payload=StoredIn({plugin, store}))` so the
  **existing provisioning reader** (`Plugin_Structure` / `StorageRef.getFieldStore`) provisions the
  store. (It must **not** feed the pending-upload **claimer** `StorageRefFields` — offload objects
  are written durably up front and are never "pending"; keep that reader `@storageRef`-only.)

**ppx implementation** (`packages/reventless-ppx/src/ppx/OffloadInference.ml`, template
`StorageRefInference.ml`; record parsing via `StateAnnotations.find_record_str` + an int matcher;
wire into `ReventlessPpx.ml` right after line 697; strip the marker inline like storageRef). The
one wrinkle vs. storageRef: storageRef's emitted schema (`forStore`) is always `string` and needs
no inner schema, whereas `@offload`'s codec needs the **field's inner schema**. Recommended: the
ppx emits `@s.matches(Reventless.Offload.forStore(~store, ~threshold?, <innerSchema>))`, deriving
`<innerSchema>` from the field's type name by sury convention; **escape hatch** — where derivation
is awkward, write the `@s.matches(Reventless.Offload.optionSchema(innerSchema, ~store, …))` helper
by hand (exactly what the `StorageRef` tests do with `StorageRef.forStore` directly). **The first
consumer uses the explicit helper form**, because `pluginDefinition` already hand-writes its
`@s.matches(…OptionSchema)` helpers.

### Producer helper (the "easy for clients" surface)

```
Offload.prepare(value, ~schema, ~store, ~threshold, ~upload): promise<payload<'a>>
```

Serialize `value` via `schema`; if under the effective threshold return `Inline(value)`; else hash
the bytes (sha256), call the injected `~upload` transport for key `sha256/<hash>`, and return
`Offloaded{store, key, hash, bytes}`. The `~upload` transport is **pluggable per environment**:

- **deploy-time (Pulumi, the first client):** declare an `aws.s3.BucketObjectv2` with a
  content-addressed key — **not** an imperative SDK PUT inside `.apply` (forbidden: "never create
  resources inside `.apply`"). See the deploy-time decision below.
- **local dev:** `LocalObjectStore.put` (in-process).
- **Node/seed and, later, browser:** direct PUT with credentials, or a content-addressed presign
  variant (deferred — not needed for v1).

**Deploy-time decision — offload the plugin fields unconditionally.** The Inline-vs-Offloaded choice
is size-dependent, but at deploy time the content is `Pulumi.Output`-wrapped, so branching on its
size to conditionally create a resource hits the Output-conditional-resource problem. The two plugin
fields are known-large (~74 KB / ~32 KB), so the deploy-time producer **always** offloads them
(always creates the `BucketObjectv2`, always emits `Offloaded`). The inline arm still exists in the
type (for backward-compat decode and for non-Pulumi clients holding the value synchronously); it is
simply not exercised by the plugin producer. Revisit only if tiny-plugin structures under the
threshold prove common enough to matter.

### Dedicated content-addressed offload store (Variant 1)

A framework store/prefix whose **key is the content hash**, separate from user-upload stores. It
is immutable and content-addressed; user-upload stores stay UUID-keyed and keep their
pending-claim/expiry lifecycle untouched. Provisioned via `Capability_ObjectStore_S3` (AWS) /
`LocalObjectStore` (dev) from the `@offload` marker declaration. Rationale and the rejected
Variant 2 (extending presign to accept client-supplied keys) are recorded in the analysis; the
short version: keep the security-sensitive presign path and its claim/expiry machinery untouched,
and the v1 producers (deploy-time Pulumi, Node) write directly.

### Reader helper + the two resolve environments

```
Offload.resolve(payload, ~fetch): promise<'a>
```

`Inline` returns the value directly; `Offloaded` calls the injected `~fetch` for the key and decodes.
Keys are content-addressed and immutable ⇒ a **per-hash cache** makes each object fetch-at-most-once
per process. Offloading **both** fields means resolve runs in two environments:

- **`apiSchemaFragment` → deploy-time only.** Add resolve where a *stored* fragment is decoded:
  `aws/src/Platform.res` `preResolversSchemaHook` (:751) → `AppSync_Adapter` (:288/444/448) /
  `AppSync_SdlDecorate.res:95`. `Plugin_Builder`'s own decodes (:305/317/328) act on a
  freshly-built inline fragment, not a ref — no resolve needed there. The deploy-time `~fetch` is
  an S3 GET (Pulumi has store access).
- **`structure` → runtime Lambda + local + tooling.** Add resolve in
  `Platform_ComponentDefinitions_Lambda_Ops.res` (the one read-model-OUT consumer; this Lambda
  gains an offload-store **GET** — its own IAM + store-location config), and in the local
  in-process (`local/src/Platform.res`) and Node-tooling (`EmitCapabilities`/`CapabilityManifest`)
  paths if refs are allowed to reach their in-process/inline values. This is the read-side GET
  seam — contained to one Lambda and effectful infra code (not pure `decide`), far smaller than a
  command-side write seam.

`PluginsProjection.displayState` (`:57-58`) keeps passing the ref through into the read model
unchanged — **no resolve at projection time**; resolution happens only at the points of use above.

### Threshold precedence chain

Effective threshold resolved when the client calls `prepare()` (client-side, not emit-time),
most-specific wins: (1) per-field `@offload({…, threshold})`; (2) platform config default
(`Platform.MakeWithConfig`'s `offloadThreshold`); (3) framework default **8 KB**. Because both arms
resolve to identical bytes on read, **retuning is always safe** — no wire change, no re-encoding,
existing events stay valid; it affects only how future values are split. (Deferred: a runtime env
override — a blunt global that can't express per-field intent; add only on real ops need.)

### Serialization / backward compatibility

The retyped fields live on `pluginDefinition` (`reventless/spec/src/components/Plugin.res:500-533`),
shared across **seven** event variants + `versionSupersededData`'s two, mirrored on
`PluginsReadModelSpec.res:27/33` (and `queryResult` 75/77). Constraints:

- Keep the `@s.matches(_jsNullable(…))` option pattern (Plugin.res:105-114/491): the option must go
  through `js_nullable` (`T | null`, not `T | undefined | null`) or it fails `jsonableValidation`
  inside the event union. The new schema is `_jsNullable(Offload.optionSchema(innerSchema, …), ())`.
- The **frozen corpus must stay decodable** (`PluginLifecycleCorpusTest`, fixtures in
  `tests/fixtures/plugin-lifecycle/`, captured off a deployed log — **never re-cut**). The untagged
  decode (above) is what keeps legacy inline payloads green.
- **The codec must preserve the event decode's tolerance (found during implementation).** A first
  cut built the codec as `S.json->S.transform` whose `Inline` arm did a nested
  `S.parseJsonOrThrow(json, innerSchema)`. That is a **strict** parse and bypasses the
  schema-evolution **healing** `Message.decode` applies (older fixtures rely on missing nested
  fields — e.g. `requiredStoreDeclarations[].annotation`, older `kind` — being filled), so the
  corpus and `MessageTest` tolerant-decode cases threw. The codec must instead let sury apply the
  inner schema through its **normal pipeline** so it inherits that tolerance — i.e. an untagged
  `S.union([<offloaded-object> → Offloaded, innerSchema → Inline])` (sury tries `Offloaded` first,
  falls through to the inner schema for legacy records), not a manual nested parse. Re-verify
  against `PluginLifecycleCorpusTest` + `MessageTest` after the change.

## Implementation notes (discovered during build)

**Producer runs through a hook, not `prepare`.** `Plugin_Builder` is core
(provider-agnostic) and cannot create an S3 resource, and the plugin's values are
`Pulumi.Output`-assembled — so the imperative `Offload.prepare` does not fit. Instead a
`Plugin_Helpers.offloadHook: ref<option<(~store, ~bytes) => offloadedRef>>` (register/clear,
same shape as `onPluginDeployedHook`) is set by an object-writing provider. `Plugin_Builder`
reads the two fields (concrete at build time) and, before the `pluginDefinition`
`Pulumi.Output.apply`, calls the hook to content-address each value or falls back to `Inline`
when unset. **Done + green** (core seam; local leaves the hook unset ⇒ stays `Inline`).

**AWS hook (remaining, deploy-validated).** In `aws/src/Platform.res`, register the offload
hook before `P.make()` and clear after (mirror `currentDeployTarget`, :2102/:2117). The hook:
sha256 the bytes (Node crypto), `PulumiAws.S3.BucketObject.make` under key `sha256/<hash>` in a
dedicated offload bucket, return `{store, key, hash, bytes}`. Provision the two content-addressed
stores (`pluginStructures`, `pluginApiFragments`) via the existing store loop
(`Capability_ObjectStore_S3.make`, :1711) and surface them in the `objectStores` export (:1841).
The `BucketObject.make` reference pattern already exists at :2053.

**Resolve (remaining, deploy-validated) — REFINED after verifying readers.** Only **`structure`**
has a runtime reader: `Platform_ComponentDefinitions_Lambda_Ops.res:50`
(`item->Dict.get("structure")->filterStructure`, which *drops the row* if it can't decode the
structure JSON). So offloading `structure` **requires** resolving here (grant that Lambda
offload-bucket GET IAM; thread the bucket name into its config; the resolve is at raw-JSON level —
detect the `$offload` sentinel key, GET the object, substitute). **`apiSchemaFragment` needs NO
resolver**: every consumer of it (`GraphQL_Stitcher`/`SchemaInspector`/`preResolversSchemaHook`)
takes a *fresh* fragment built by `Plugin_Builder`, never the stored payload, and the stored field
is in `pluginUIOnlyExcludeFields`. So offloading it is safe write-only size savings. This is
all-or-nothing with the producer: a producer-only push offloads `structure` and the
ComponentDefinitions Lambda then drops every plugin row (AutoUI component graph empties) — so the
`structure` resolver + its IAM/config must land in the same change and be deploy-validated first.

**Bucket topology (remaining).** A platform-level content-addressed offload bucket (the
ComponentDefinitions Lambda is platform-level and needs GET; plugin stacks need PUT), created in
the platform stack and exported (like `objectStores`, ~:1841); plugin stacks read it via the
existing `objectStores` StackReference (~:179) for the producer's `BucketObject` writes.

## Steps

1. **Spec primitive** (`reventless/spec`): `Semantic.Id.offload`; `Offload` module — `payload<'a>`
   type, the untagged backward-compat codec, `optionSchema`/`forStore` helpers marking `StoredIn`,
   threshold plumbing.
2. **ppx** (`reventless-ppx`): `OffloadInference.ml` (record + string forms, read from
   `pld_attributes`, strip inline, emit `@s.matches(Offload.forStore(…))`); wire into
   `ReventlessPpx.ml:697`. Build via dune; **republish** (CI `publish-ppx.yml` or
   `scripts/publish-ppx-local.mjs`, all `npm/*` + root versions bumped in lockstep) — CI stays red
   until republished.
3. **Provisioning** (`reventless/core` + `aws`/`local`): recognize `@offload` stores in the
   `Plugin_Structure` provisioning reader (not the claimer); provision the dedicated
   content-addressed store on AWS (`Capability_ObjectStore_S3`) and local (`LocalObjectStore`).
4. **Producer helper** `Offload.prepare(~upload)` + transports: deploy-time `BucketObjectv2`
   transport; local `LocalObjectStore.put`; (Node direct-PUT).
5. **Reader helper** `Offload.resolve(~fetch)` + per-hash cache; deploy-time S3-GET fetch and
   runtime-Lambda S3-GET fetch.
6. **Retype the two fields** on `pluginDefinition` (Plugin.res) + read-model mirror
   (PluginsReadModelSpec) to `option<Offload.payload<…>>` via the `_jsNullable(Offload.optionSchema(…))`
   helper.
7. **First consumer — produce**: `Plugin_Builder` calls `prepare` (unconditional offload) for both
   fields when assembling `pluginDefinition`; `Connect` carries the ref; `decide` passes it through.
8. **First consumer — resolve**: `apiSchemaFragment` at the deploy-time AppSync path; `structure`
   in `Platform_ComponentDefinitions_Lambda_Ops` (+ local + tooling). Grant that Lambda offload-store
   GET IAM; thread the store location into its config.
9. **Config surface**: `offloadThreshold` on `Platform.MakeWithConfig`; per-field marker override.
10. **Tests** (below).

## Tests

- Untagged decode: a legacy inline `structure`/`apiSchemaFragment` JSON decodes as `Inline`; a
  frozen-corpus fixture stays green (`PluginLifecycleCorpusTest`).
- `prepare`: value over threshold → `Offloaded` (object written to store, content-addressed key);
  under threshold → `Inline` (no write); two identical values → identical key (dedupe).
- `resolve`: `Offloaded` round-trips to identical bytes; per-hash cache fetches once.
- Threshold precedence: per-field marker > platform config > 8 KB; a straddling payload splits
  differently under each, both reading back identical.
- Deploy path: producing a `pluginDefinition` offloads both fields; the emitted `VersionConnected`
  is < 1 KB; `Connect`→`decide`→event passes the ref through unchanged (`PluginBehavior_GWT`).
- Read path: `structure` resolves in the component-definitions consumer; `apiSchemaFragment`
  resolves at the AppSync stitch; `PluginsProjection` passes the ref through without fetching.
- Provisioning: the `@offload` store is provisioned (declaration reader) and is **not** added to the
  claimer's table.
- Generality: a synthetic `@offload` field on a test spec exercises `prepare`/`resolve` independently
  of the plugin aggregate.

## Object lifecycle

Content-addressed + immutable ⇒ never mutated. Default **never-delete** (objects small vs. the value
of replayable history; dedupe keeps counts low). **GC caveat:** as a general marker, a domain may
point `@offload` at high-cardinality non-deduping fields, so before advertising it generally, design
ref-counted reclamation (an object may not be removed while any live event references its hash) —
and note the **GDPR erasure vs. immutability** tension for personal data (crypto-shred via
per-object keys, or keep offload off PII). Deferred for the plugin consumer.

## Risks / trade-offs

- **Two-store durability** — a replay now depends on the object store too; the referenced hash must
  always be resolvable (write-before-reference ordering; never-delete/ref-counted objects).
- **Read-side GET seam for `structure`** — one runtime Lambda gains offload-store GET + IAM. Modest
  and contained, but real; `apiSchemaFragment` has no runtime read cost (deploy-time only).
- **Deploy-time unconditional offload** — the plugin producer always writes an object even for a
  small structure; accepted to avoid Output-conditional resource creation.
- **ppx inner-schema derivation** — the general `@offload` shorthand must synthesize the field's
  inner schema; the explicit-helper escape hatch (used by the first consumer) de-risks it.
- **Speculative generality** — mitigated by driving the API from the plugin case while placing the
  type/helpers in shared modules so consumer #2 is a one-annotation opt-in.
- **ppx republish gate** — CI is red until the rebuilt ppx binaries are republished in lockstep.

## Scope

- **Adds:** a general client-driven `@offload` primitive (inline-or-ref, content-addressed,
  client-uploaded) reusing the `@storageRef` marker/provisioning machinery and a dedicated
  content-addressed store — **no** command-side write seam.
- **Reduces:** per-event size for the plugin's large fields and total stored bytes via cross-version
  dedupe (item size, RCU/WCU, stream bytes, event-body logging).
- **Does not:** change how many events are appended, alter `@storageRef`, add a runtime command-side
  seam, or touch other aggregates beyond opting the plugin fields in.
