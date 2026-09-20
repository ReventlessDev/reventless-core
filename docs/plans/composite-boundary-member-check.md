# Plan: a composite boundary is never checked for its members

**Status**: Proposed (2026-09-21) — found while giving the VS Code authoring surface a way to
reason about partitions, not from a failure in the field.<br/>
**Nature**: a missing build-time guard, symmetric with one the single-key path already has. No
schema change, no migration, no runtime behaviour change for a correctly modelled boundary.<br/>
**Touches**: `reventless/spec/src/components/DcbTag.res` (`deriveBoundaryPartition`), its tests,
and — separately — the tooling that mirrors the derivation.

Related: [dcb-empty-tag-values-break-append](done/dcb-empty-tag-values-break-append.md) (its **D4**
is this problem's deferred runtime sibling), [composite-partition-tag](done/composite-partition-tag.md)
(the feature), [dcb-tag-scope-inference](done/dcb-tag-scope-inference.md) (the single-key path and
the check this one is missing).

## Motivation

`deriveBoundaryPartition` has two legs, and only one of them checks its own premise.

The single-key leg refuses a slice whose event does not carry the key it is partitioned by:

> `DCB slice ${s.name} is partitioned by ${key}, but its event ${eventType} carries no ${key} tag
> (it carries …) — add ${key} to the event, or declare the partition with @partitionTag`

The composite leg returns before reaching it:

```rescript
switch compositePartitionOf(slices->Array.map(s => s.eventSchema)) {
| Some(spec) => {partitionBySlice: Dict.make(), partitionTag: Composite(spec)}
| None => /* …resolve, then check every event carries its key… */
```

So a boundary is composite as soon as **any** event in it carries `@compositePartitionTag`, and
nothing then asks whether the **rest** of the boundary's events carry those members. Composite is
declared for the whole boundary, so every slice in the plugin is filed under that spec whether or
not its events know about it.

### What actually happens, and why it is not the corruption it first looks like

`getCompositePartitionKeyValue` resolves a missing member with `Option.getOr("")`, and an empty
tag value is **deliberate, documented behaviour**: D1 of the empty-tag plan skips the `tag_<key>`
attribute, the event is appended, it stays readable through its partition and appears in composite
reads. Nothing crashes and nothing is lost.

The harm is a **consistency** one instead, and it is quieter. Every event missing the same member
resolves that segment to `""`, so events that belong in different partitions are filed in one:

- their appends contend on a fence that should never have been shared;
- a decision read scoped to that partition sees foreign events;
- and the degenerate end of it — every member empty — is exactly the case the empty-tag plan's
  **D4** described as "putting every event of that slice in one partition", judged *a modelling
  error rather than a storage one* and deferred.

D4 was right that it is a modelling error. This plan is the conclusion that follows: a modelling
error the build can see should be refused by the build, not surfaced at append time as a debug
log. The single-key path already takes that position for its own premise.

## Decision — check the members, at the same point the single-key path checks its key

**D1 — refuse a composite boundary whose events do not all carry the members.** For each slice in
the boundary, every event type that carries any tag at all must carry every member of the
composite spec. Name the slice, the event type, the missing members and the spec, the way the
single-key message does.

**D2 — a payload-less or untagged event is not a violation.** The single-key check already guards
with `tagKeys->Array.length > 0`: an arm that carries no tags is not filed by tag and has nothing
to be missing. Keep that exemption, or every payload-less arm in a composite plugin becomes an
error.

**D3 — this stays a build-time check, and D4 stays deferred.** A runtime signal would fire once
per append on a boundary the build already accepted. If D1 lands, the only way to reach D4's case
is an empty *value* at runtime, which is legal by D1 of the empty-tag plan. Revisit only if that
shows up in the field.

**D4 — the error names the two ways out.** A member missing from one slice's events is either a
field that slice genuinely does not have — in which case the boundary should not be composite —
or an omission. Say both, as the single-key message says "add the key, or declare the partition".

## Phases

### Phase 1 — the check ⏱ ~0.5d

In `deriveBoundaryPartition`'s composite branch, before returning `Composite(spec)`: walk
`extractTagKeysByEventType(s.eventSchema)` per slice, and for every event type with a non-empty
tag set, assert every `spec.keys` member is present. Throw naming slice, event type and the
missing members.

**Verify:** a boundary where one slice's event omits a member throws, naming it; a boundary where
every event carries every member derives as it does today; a payload-less arm in a composite
boundary still derives.

### Phase 2 — a conformance case ⏱ ~0.5d

The empty-tag plan's D2 added a conformance case pinning that an empty tag value appends and is
readable. Add the sibling: **two events missing the same member do not end up sharing a
partition**, because the build refuses the boundary before they can. That is the case that makes
the contention consequence explicit rather than inferred from the key construction.

### Phase 3 — the tooling mirror 🔗 tools

The VS Code tooling runs `DcbScopeInference` unconditionally, so a composite plugin reports
**every** slice as ambiguous — its members are typically not `*Id`-shaped, so `producedKeys` comes
back empty — while the app builds and runs. The tooling has to short-circuit on a composite
boundary exactly as this function does. Tracked in tools'
`forward-codegen-pipeline.md` §"The authoring surface — what is left", A3; listed here so the two
halves of the derivation are not fixed apart.

## Verification

- `DcbTagTest` / a new case: the throw fires, names the slice and the missing member, and does not
  fire for a well-formed composite boundary or a payload-less arm.
- The existing composite integration slices (`EpCompositeSlice`, the `SyncResource` shape) still
  derive unchanged — they are the evidence the check is not stricter than the feature.
- Full `reventless/spec` suite green; no golden or example change expected, since a boundary that
  passes today and fails after is by definition one that was filing events under a shared key.

## Non-goals

- **Changing what an empty tag value means.** D1 of the empty-tag plan stands: permitted,
  participates in the composite key, not individually indexed.
- **Making composite per-slice.** It is a whole-boundary strategy by construction; that is what
  makes this check necessary rather than a per-slice concern.
- **Teaching `DcbScopeInference` about composite.** It is deliberately outside the inference, and
  generalising `partitionBySlice` to a multi-key shape would be work with no consumer.
