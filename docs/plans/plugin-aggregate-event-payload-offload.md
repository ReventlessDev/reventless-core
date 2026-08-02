# Plan: a general `@offload` field primitive, first applied to plugin-aggregate payloads

**Date:** 2026-08-02
**Status:** Proposed. Not started.

## Problem

The plugin lifecycle aggregate's `VersionConnected` event embeds the full plugin
definition inline. Two fields dominate the payload:

- `structure` — the plugin's component structure (UI fragments and all) — **~74 KB**
- `apiSchemaFragment` — the plugin's API/SDL fragment — **~32 KB**

Everything else in the event (`id`, `kind`, `version`, `name`, `apiTarget`,
`eventCollector`, `dcbEventLog`, the extension descriptors) is under a few hundred bytes
combined. Observed `VersionConnected` events run **107 KB**, with the aggregate's event
log averaging **~70 KB per event** and a max over **130 KB**.

Events are immutable history. So each fat `VersionConnected`:

- costs its full size in the event-store item (and its read/write capacity),
- is re-read in full on **every** projection rebuild of that aggregate,
- is delivered in full through the change stream to every projection consumer,
- and is carried in full by anything that logs the event body.

The payload is also highly **repetitive across versions**: a plugin that re-registers
with an unchanged (or barely-changed) structure re-embeds ~106 KB that is byte-identical
to a previous version's. The log accumulates many near-duplicate large blobs that live
forever.

The plugin aggregate is the *first* place this bites, but nothing about the pain is
plugin-specific. Any aggregate or slice with a potentially-large serialized field
(imported catalogs, large documents, snapshots, fat DCB payloads) hits the same wall.

## Goal

Introduce a **general framework primitive** — an `@offload` field marker — that
transparently moves a large serialized field to a platform object store, content-addressed
by hash, carrying only a **reference** in the event; small values stay inline. Then apply it
to `VersionConnected`'s two large fields as its **first consumer**.

A `VersionConnected` event shrinks from ~107 KB to **under 1 KB**. Identical structures
across versions resolve to the **same** object (free dedupe), so the object store holds one
copy of each distinct structure rather than one per registration. Because the primitive is
general, the second consumer is a one-line opt-in rather than a copy-paste.

## Where this fits: the `@storageRef` family

The framework already has a general "a field's value lives in a platform object store"
mechanism — **`@storageRef("store")`** (`reventless/spec/src/semantic/StorageRef.res`),
backed by `Capability_ObjectStore_S3` (AWS) and `LocalObjectStore` (dev), with
provisioning-from-declaration and wipe-discovery tagging, and a deploy-time scanner
(`reventless/core/src/components/Api/StorageRefFields.res`) that reads the markers so the
store requirement is visible to provisioning.

`@offload` is a **sibling** of `@storageRef`, not the same thing. Both say "this field's
value lives in a store," and both should route through the same `Semantic.mark` machinery
and the same object-store seam. They differ in who produces the object and how it is
referenced:

| | `@storageRef` (exists) | `@offload` (this plan) |
|---|---|---|
| Producer | the **browser**, via presigned PUT *before* the command | the **framework**, transparently on the emit path |
| Value on the wire | opaque origin-relative path `string` | `Inline \| Offloaded{store,key,hash,bytes}` variant |
| Inline arm | none (always a ref, or `""`) | yes — a size threshold decides |
| Addressing | UUID per upload | content-addressed hash → cross-version dedupe |
| Reader | sees the ref as the value | a resolve helper hides inline-vs-offloaded |

The design reuses everything the two share (the store seam, the semantic marker, the
deploy-time store-requirement scan) and adds only what is genuinely new (the inline-or-offloaded
variant, content-addressed write, resolve-with-cache).

## Design

### The `payload<'a>` (inline-or-offloaded) type

Model an offloadable field as a variant rather than a raw value:

```
type payload<'a> =
  | Inline('a)                                    // small payloads stay embedded
  | Offloaded({store: string, key: string, hash: string, bytes: int})
```

This is a **backward-compatible spec change** wherever it is adopted: every event already
in history decodes as `Inline`, and only newly-appended large payloads are written as
`Offloaded`. No migration of existing event logs is required — a reader handles both arms.

### The marker and its schema (`reventless/spec`)

Mirror `StorageRef.res`. Add a `Semantic.Id.offload` alongside `storageRef`, and an
`Offload` module (`reventless/spec/src/semantic/Offload.res`) holding:

- the polymorphic sury schema for `payload<'a>` (legacy values decode as `Inline`), marked
  via `Semantic.mark(~id=Semantic.Id.offload, ~payload=StoredIn({plugin, store}))` so the
  store requirement is expressed the *same way* `@storageRef` expresses it — reusing the
  existing `StoredIn(storeTarget)` payload variant unchanged;
- an `@offload("store")` ppx shorthand (and `"<plugin>.<store>"` cross-plugin form),
  matching `@storageRef`'s ergonomics, plus a record form
  `@offload({store: "s", threshold: 16384})` that carries a per-field threshold override
  (mirroring how `@index("name")` widens to `@index({name, projection})`). The threshold
  is a *hint*, not part of the field's meaning — it is resolved at emit time (see below),
  so it never touches the wire contract or what a reader sees.

Because the marker uses `StoredIn`, the deploy-time scanner that today collects `@storageRef`
stores (`StorageRefFields`) extends to collect `@offload` stores with no new detection
branch — a field of this type *requires* a store to exist, and provisioning already knows how
to read that requirement.

### Write path (framework emit side) (`reventless/core`)

A reusable write helper, invoked wherever an `@offload` field is emitted. For the field's
serialized bytes, compared against the **effective threshold** (resolved by the precedence
chain in "Config surface" below):

- if the size is below the effective threshold, keep it `Inline` — a tiny payload pays no
  object-store round trip;
- otherwise, hash the bytes, `PUT` them to the field's declared store under a
  content-addressed key (`sha256/<hash>`), and substitute `Offloaded{…}`.

The object **must be durably written before the event is appended** — the event references a
key that has to exist for every future replay. Content-addressing makes the write idempotent:
the same structure re-registered writes to the same key (a no-op if present), which is exactly
what gives the cross-version dedupe.

### Read / projection path (`reventless/core`)

A reusable resolve helper returns the bytes for either arm: `Inline` yields them directly;
`Offloaded` fetches from the store. Because keys are content-addressed and immutable, the
fetch is cacheable forever — a per-hash cache means each distinct object is fetched at most
once per process, regardless of how many versions or replays reference it.

### Store seam

`@offload` writes to the **same** platform object-store seam `@storageRef` uses
(`Capability_ObjectStore_S3` on AWS, `LocalObjectStore` in dev), under a framework-internal
content-addressed prefix. Provisioning, attribution tagging, wipe-discovery, and the
local/AWS split all come for free — no new store type is introduced.

### First consumer: `VersionConnected`

Retype `VersionConnected`'s `structure` and `apiSchemaFragment` as `@offload` fields in
`reventless/core/src/plugin/lifecycle/PluginSpec.res` (verify the exact path when
implementing). `PluginBehavior`'s emit path calls the write helper; `PluginsProjection` and
any other `VersionConnected` reader call the resolve helper.

### Object lifecycle

Content-addressed + immutable objects are never mutated. For the plugin consumer the safe
default is **never delete** (the objects are small relative to the value of a self-consistent,
replayable history, and dedupe keeps the count low).

**Generalization caveat:** never-delete is safe *because* plugin structures are small,
deduped, and low-cardinality. As a general marker, a domain will eventually point `@offload`
at a high-cardinality, non-deduplicating large field, and never-delete becomes an unbounded
store. Reclamation may be **deferred** for the plugin consumer, but the lifecycle/ref-counting
model must be **designed** before `@offload` is advertised as a general-purpose marker — if
reclamation ever runs, it must be ref-counted against the live event history so an object is
never removed while any event still references its hash.

## Steps

1. **Spec primitive** (`reventless/spec`): add `Semantic.Id.offload`; add an `Offload`
   module (`payload<'a>` type + polymorphic sury schema marked with `StoredIn`, legacy →
   `Inline`); add the `@offload("store")` ppx shorthand mirroring `@storageRef`.
2. **Deploy-time scan** (`reventless/core`): confirm/extend `StorageRefFields` (or a shared
   sibling) so `@offload` stores are collected as store requirements via the shared
   `StoredIn` payload — ideally no new branch.
3. **Write helper** (`reventless/core`): threshold check → hash → content-addressed PUT to the
   declared store → `Offloaded` substitution, write-before-append. Needs an object-store
   handle on the command side (the same seam `@storageRef` uses).
4. **Resolve helper** (`reventless/core`): inline-or-offloaded → bytes, with a per-hash cache.
5. **First consumer**: retype `VersionConnected.structure` and `apiSchemaFragment` as
   `@offload`; wire `PluginBehavior` (emit) and `PluginsProjection` (read).
6. **Backward compatibility**: confirm legacy inline events decode unchanged; add a fixture
   from a pre-change `VersionConnected` body.
7. **Config surface — the threshold's precedence chain** (most specific wins):
   1. **Per-field marker** — `@offload({store, threshold})` on the field. Use for a field
      known to always warrant offloading (or never), independent of the platform default.
   2. **Platform config default** — a single `offloadThreshold` on `Platform.MakeWithConfig`,
      the default for every `@offload` field that does not override it. This is the knob most
      deployments actually turn.
   3. **Framework default — 8 KB** — used when neither of the above is set.

   The effective threshold is resolved at **emit time** in the write helper, not baked into
   the spec. Because it is pure write-path policy — both `Inline` and `Offloaded` resolve to
   identical bytes on read — **changing it at any level is always safe**: no wire change, no
   re-encoding, and existing events (already written under an old threshold) stay valid and
   readable. Retuning affects only how *future* events are split.

   The target store is declared per-field by the marker (step 1), not part of this chain.

   *Deferred, not in the first cut:* a runtime env override (e.g.
   `REVENTLESS_OFFLOAD_THRESHOLD`) read by the command-handler tier, to let ops retune without
   a redeploy. It is a blunt global (it can't express per-field intent), so it is worth adding
   only if a real ops need appears; the marker + platform-config chain covers the design cases.
8. **Tests**:
   - large `structure` → `Offloaded` emitted; round-trips to identical bytes on read
   - small structure → stays `Inline`; no object written
   - two versions with identical structure → identical key (dedupe proven)
   - legacy inline event still decodes and projects
   - event appended only after the object write resolves (ordering)
   - deploy-time scan reports the `@offload` store as a store requirement
   - (generality) a second, synthetic `@offload` field on a test spec exercises the
     primitive independently of the plugin aggregate
   - (threshold precedence) a per-field marker threshold overrides the platform default,
     which overrides the 8 KB framework default; a payload straddling two thresholds is
     split differently under each, and both encodings read back to identical bytes

## Risks / trade-offs

- **Speculative generality.** Building a general marker for one consumer risks
  over-abstraction. Mitigated by driving the API from the plugin case and keeping the surface
  minimal — but the type and helpers live in shared modules (`spec`/`core`) from day one, so
  the second consumer is an `@offload("store")` opt-in, not a copy-paste.
- **Two-store durability.** The event no longer self-contains its payload; a replay now
  depends on the object store as well as the event log. This is the inherent trade of moving a
  payload out of the event. Mitigate with write-before-append ordering and never-delete (or
  ref-counted) objects, so a referenced hash is always resolvable.
- **Cold-path fetch latency** on projection rebuilds — mitigated by the content-addressed
  per-hash cache (immutable ⇒ cache-forever, fetch-at-most-once).
- **Lifecycle at scale** — see the generalization caveat above: the never-delete default is
  safe for the plugin consumer but must have a reclamation model designed before the marker is
  offered generally.
- **Threshold tuning** — too low adds object round-trips for medium payloads; too high leaves
  bloat inline. 8 KB is the framework default, overridable per-field (marker) or per-platform
  (config); see the precedence chain in step 7. Retuning is always safe — it is write-path
  policy with no wire or read-back effect — so the default can be revisited against the
  observed size distribution without touching existing history.

## Scope

- **Adds:** a general, reusable `@offload` field primitive in the `@storageRef` family —
  transparent, content-addressed, inline-or-offloaded field spill — reusing the existing
  object-store seam, semantic marker, and deploy-time store-requirement scan.
- **Reduces (via the first consumer):** per-event size for large plugin structures, and total
  stored bytes via cross-version dedupe — lowering item size, read/write capacity,
  stream-delivery bytes, and any event-body logging for the plugin aggregate.
- **Does not:** change how *many* events are appended, alter `@storageRef`, or touch any other
  aggregate beyond opting the plugin fields in. It is a size fix for large serialized fields,
  orthogonal to event-count concerns elsewhere.
