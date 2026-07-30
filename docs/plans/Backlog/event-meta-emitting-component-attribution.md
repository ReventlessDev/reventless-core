# Plan: Stamp the emitting component on every durable event's `meta`

**Related.** [event-source-from-channel-not-stored-service.md](event-source-from-channel-not-stored-service.md)
— the complementary simplification: derive the routing `service` from the channel and stop
persisting it per row, so the stored identity meta this plan adds (`component`) becomes the
*only* identity a row carries. The two are best scheduled together.

## Problem

A durable event carries no attribution to the **model component** (slice / aggregate) that
produced it. The `meta` envelope records `service`, but `service` is not the producer:

1. At the DCB event-log append boundary,
   [`DcbEventLog_Operations.append`](../../../reventless/core/src/components/DcbEventLog/DcbEventLog_Operations.res#L117-L133)
   **normalises `meta.service` to the event-log's own identity** (`"<plugin>DcbEventLog"`)
   on every event, because EventCollector dispatch and SNS consumers key on `meta.service`
   and it must match the log identity — not the caller's. The producing component's identity
   is discarded here.
2. Even upstream of that, `service` is a plugin/service-level name, not the component
   (slice/aggregate) that ran `decide` and emitted the event.

So a consumer holding a stored event cannot answer "which component produced this?" from the
event alone. The only recovery is a **static, spec-side event-type → producing-slice map**,
which is (a) external to the event and (b) ambiguous whenever the same event type is emitted
by more than one component. Provenance that is intrinsic to the event — the way
`causationId` links an event to its command — does not exist for the emitting component.

This matters for any consumer that attributes events back to the model: observability /
activity signals, audit/provenance, per-component analytics, and stream processors that fan
a shared per-plugin DCB log back out to component granularity. Classic per-aggregate
`EventLog` tables encode the component implicitly in the table identity; the shared DCB log
does not, so the shared-log path has strictly less attribution than the classic one.

## Goals

- Every durable event carries the **producing component's name** in `meta`, set once at the
  point the event is stamped from a command, and never overwritten downstream.
- Additive and backwards-compatible: events written before the change decode fine (the field
  is absent → `None`).
- The field survives the DCB append `service`-normalisation (it is a *separate* key, so it is
  not touched).
- Works for both the DCB (`StateChangeSlice`) and classic (`Aggregate`) producer paths, and
  any other slice that stamps event meta from a command.

## Non-goals

- Reusing or repurposing `meta.service`. Its value and its normalisation are load-bearing for
  EventCollector routing; leave it exactly as-is. Add a sibling field.
- Making the field required. Existing stored events lack it; required would break decode.
- Stamping component as a DCB **tag**. Tags define consistency boundaries; the producing
  component is *provenance metadata*, not a boundary, and must not enter the tag set (that
  would fragment partitions and the composite fence). It belongs in `meta`, beside
  `causationId` / `correlationId`.
- Any consumer-side use of the field (analytics, stream aggregation, read models). This plan
  only makes the attribution *available* on the event; who reads it is out of scope.

## Approach

Mirror the existing `causationId` precedent (an optional `meta` field populated at stamp
time, additive, round-trips through the flat on-disk shape).

### 1. `Message.meta` — add the field

In [`reventless/spec/src/types/Message.res`](../../../reventless/spec/src/types/Message.res#L29-L45)
(the `meta` record already carries an optional `causationId?`):

```rescript
@schema
type meta = {
  service: service,
  ...
  correlationId: string,
  @s.optional causationId?: string,
  @s.optional component?: string,   // NEW — producing model component (slice/aggregate) name
}
```

`@s.optional` keeps decode backwards-compatible: pre-change events decode with
`component = None`.

### 2. Flat on-disk round-trip — add to `metaKeys`

The flat DynamoDB shape is bridged by `decomposeMeta` / the `metaKeys` allow-list in
[`reventless/core/src/Message.res`](../../../reventless/core/src/Message.res#L290-L301).
Add `"component"` to `metaKeys` so it is (a) flattened to a top-level attribute on write —
which also makes it GSI-projectable for free, same as every other meta key — and (b)
re-separated from the envelope and reassembled into `meta` on read. **No table migration**:
a new top-level attribute is additive; old rows simply lack it.

### 3. Stamp at the producer — where the component name is in scope

The producing component name is `Spec.name`, in scope in each command-handling callback:

- **DCB path** —
  [`StateChangeSlice_Callback`](../../../reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L73)
  derives event meta via `Message.deriveMeta(~parent=parentMeta)` (`Spec.name` already used
  for `comp`/metrics at `:27`, `:239`). Stamp `component: Some(Spec.name)` here, before the
  events reach `dcbEventLog.append` (`:366`). Because `append` only rewrites `service`
  (step 1's Problem #1), the `component` key passes through untouched.
- **Classic path** —
  [`Aggregate_Callback.updateMeta`](../../../reventless/core/src/components/Aggregate/Aggregate_Callback.res#L57)
  (the same site that already stamps `causationId`). Set `component: Some(Spec.name)`.
- **Any other command→event translation** (automation / inbound slices, if they stamp event
  meta) — same one-line stamp. Enumerate as in step-3 below.

### 4. Confirm `deriveMeta` / `generateMeta` defaults

`deriveMeta(~parent=…)` inherits parent meta; ensure `component` is **not** inherited from a
parent (an event's producer is the current component, not the causing command's producer).
It should be set explicitly at each producer, defaulting to `None` when there is no producing
command (e.g. a scheduled task emitting spontaneously). Verify `generateMeta` /
`deriveMeta` do not carry a stale `component` through a causation hop.

## Steps

### Step 1 — Add `component` to `Message.meta`
`reventless/spec/src/types/Message.res`: add the optional field to the record + schema.

### Step 2 — Add `"component"` to `metaKeys`
`reventless/core/src/Message.res`: extend the allow-list; confirm `decomposeMeta` /
`composeMeta` (the reassembly used by the DCB and EventLog read paths) round-trip it.

### Step 3 — Stamp at every command→event producer
- `StateChangeSlice_Callback` (DCB) — stamp at the `deriveMeta` site.
- `Aggregate_Callback.updateMeta` (classic).
- Automation / inbound translation slices that build event meta from a command.
Each sets `component = Some(Spec.name)`; spontaneous producers leave it `None`.

### Step 4 — Guard the DCB normalisation
Confirm `DcbEventLog_Operations.append` (`:117-133`) still rewrites **only** `service` and
leaves `component` intact. Add a regression test asserting a stamped `component` survives
append + publish unchanged while `service` is normalised to `"<plugin>DcbEventLog"`.

### Step 5 — Tests
- `reventless/spec` (or the `Message` test): `meta` round-trip with and without `component`;
  old-format meta (no `component` key) decodes to `None`.
- `StateChangeSlice_Callback` test: a command handled by slice `S` produces events whose
  stored `meta.component = Some("S")`; multi-event command → all events carry the same
  `component`.
- `Aggregate_Callback` test: same shape for the classic path.
- DCB flat round-trip: `component` flattens to a top-level attribute and reassembles.

### Step 6 — Docs
- Update the messages/meta reference (`docs/inner-workings/messages.md` or equivalent) to
  document `meta.component` as the producing-component provenance field, alongside
  `causationId`/`correlationId`.

Move to `done/` when landed.

## Open questions

- **Name — `component` vs `emittedBy`?** `component` aligns with the framework's existing
  vocabulary (`ComponentType`, `componentName`); `emittedBy` reads more explicitly as
  provenance. Prefer `component` for consistency unless it collides with an existing meta
  reader.
- **Optional vs required.** Keep optional — required breaks decode of pre-change events and
  has no sensible value for spontaneous (command-less) producers.
- **Should `correlationId`-style inheritance apply?** No — `component` is per-event producer
  identity, explicitly *not* inherited across a causation hop (unlike `correlationId`).
  Confirm `deriveMeta` does not propagate it from the parent.
- **Interaction with `service`.** Deliberately none: `service` stays the (normalised) log /
  service identity for routing; `component` is the model producer. Two distinct facts, both
  present.

## Status

Not started.
