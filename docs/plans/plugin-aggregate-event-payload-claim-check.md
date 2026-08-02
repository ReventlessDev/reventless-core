# Plan: claim-check the large plugin-aggregate event payloads

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

## Goal

Apply the claim-check pattern to the two large fields. Store `structure` and
`apiSchemaFragment` in the platform object store, content-addressed by hash, and carry
only a **reference** (store, key, hash, byte length) in the event. A `VersionConnected`
event shrinks from ~107 KB to **under 1 KB**. Identical structures across versions
resolve to the **same** object (free dedupe), so the object store holds one copy of each
distinct structure rather than one per registration.

## Design

### Payload becomes inline-or-ref

Model each large field as a variant rather than a raw string:

```
type payload<'a> =
  | Inline('a)                                  // small payloads stay embedded
  | ExternalRef({store: string, key: string, hash: string, bytes: int})
```

`VersionConnected`'s `structure` and `apiSchemaFragment` take this shape. This is a
**backward-compatible spec change**: every event already in history decodes as `Inline`,
and only newly-appended large payloads are written as `ExternalRef`. No migration of
existing event logs is required — a reader simply handles both arms.

### Write path (aggregate command side)

When `VersionConnected` is emitted (`PluginBehavior`), for each of the two fields:

- if the serialized size is below a threshold (start at **8 KB**), keep it `Inline` — a
  tiny plugin pays no object-store round trip;
- otherwise, hash the bytes, `PUT` them to the platform object store under a
  content-addressed key (`sha256/<hash>`), and substitute `ExternalRef{…}`.

The object **must be durably written before the event is appended** — the event
references a key that has to exist for every future replay. Content-addressing makes the
write idempotent: the same structure re-registered writes to the same key (a no-op if
present), which is exactly what gives the cross-version dedupe.

### Read / projection path

`PluginsProjection` and any other consumer resolve a field through a helper that returns
the bytes for either arm: `Inline` yields them directly; `ExternalRef` fetches from the
store. Because keys are content-addressed and immutable, the fetch is cacheable forever
— a per-hash cache means each distinct structure is fetched at most once per process,
regardless of how many versions or replays reference it.

### Object lifecycle

Content-addressed + immutable objects are never mutated. The safe default is **never
delete** (the objects are small relative to the value of a self-consistent, replayable
history, and dedupe keeps the count low). If reclamation is ever needed, it must be
ref-counted against the live event history — an object may not be removed while any
event still references its hash.

## Steps

1. Add the `payload<'a>` (inline-or-ref) type to the `VersionConnected` spec in
   `reventless/core/src/plugin/lifecycle/PluginSpec.res`; retype `structure` and
   `apiSchemaFragment`.
2. Emit path in `PluginBehavior`: threshold check → content-addressed object write →
   `ExternalRef` substitution. Requires an object-store handle on the aggregate's
   command side (the framework's object-store seam).
3. Read path: a resolve-inline-or-ref helper with a per-hash cache; consume it in
   `PluginsProjection` and any other `VersionConnected` reader.
4. Backward compatibility: confirm legacy `Inline` events decode unchanged; add a fixture
   from a pre-change event body.
5. Config surface: the size threshold and the target store.
6. Tests:
   - large `structure` → `ExternalRef` emitted; round-trips to identical bytes on read
   - small structure → stays `Inline`; no object written
   - two versions with identical structure → identical key (dedupe proven)
   - legacy inline event still decodes and projects
   - event appended only after the object write resolves (ordering)

## Risks / trade-offs

- **Two-store durability.** The event no longer self-contains its payload; a replay now
  depends on the object store as well as the event log. This is the inherent claim-check
  trade. Mitigate with write-before-append ordering and never-delete (or ref-counted)
  objects, so a referenced hash is always resolvable.
- **Cold-path fetch latency** on projection rebuilds — mitigated by the content-addressed
  per-hash cache (immutable ⇒ cache-forever, fetch-at-most-once).
- **Threshold tuning** — too low adds object round-trips for medium payloads; too high
  leaves bloat inline. 8 KB is a starting point; revisit against the observed size
  distribution.

## Scope

- **Reduces:** per-event size for large plugin structures, and total stored bytes via
  cross-version dedupe — which lowers item size, read/write capacity, stream-delivery
  bytes, and any event-body logging for this aggregate.
- **Does not:** change how *many* events are appended, or touch any other aggregate. It
  is a size fix for one write path, orthogonal to event-count concerns elsewhere.
