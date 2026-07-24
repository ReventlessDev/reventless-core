# Plan: Widen the StateViewSlice projection input to the event envelope

## Status: Not started

**Date:** 2026-07-24

StateViewSlice projections receive the decoded event payload and nothing else,
while the envelope carrying `meta` (actor, producer time) and `recordedAt`
(storage timestamp) is decoded and discarded one stack frame above them. The
ReadModel side already does the right thing. This plan closes that asymmetry.

**Origin.** Identified as blocker **B4** of an Auto UI demo-readiness analysis
tracked outside this repo. That analysis lists five blockers; the other four are
UI-side or example-side — B1–B3 are tracked with the UI work, B5 is
[online-shop-hybrid-demo-data.md](done/online-shop-hybrid-demo-data.md).
This one stands on its own merits as a spec correctness fix; the UI
payoff is a consequence, not the justification.

**Execution order: step 2 of 6** (B5 → B4 → B1 → B6 → B3 → B2; the full table
with rationale is kept alongside the UI-side blocker list).
Nothing forces it this early — it has no dependencies — but it is deliberately
front-loaded: it is the long pole (a breaking change across ~17 projections,
plus a Phase 3 compile check that can re-scope the plan), so its risk should
surface before UI work is built on the assumption that it lands. It also runs
second so it stays in the same repo as step 1, whose reseed script its
live-schema change wants.

---

## Motivation

The projection signature is payload-only
([`StateViewSlice.res:94`](../../reventless/spec/src/components/StateViewSlice.res#L94)):

```rescript
let project: Spec.consumedEvent => array<Projection.action<string, Spec.state>>
```

But [`DcbEventLog.rawSequencedEvent`](../../reventless/infra/src/components/DcbEventLog.res#L30-L37)
carries both `meta: Message.meta` (which holds `time`, `user`, `service`,
correlation ids) and `recordedAt: string`, and
[`StateViewSlice_Callback`](../../reventless/core/src/components/StateViewSlice/StateViewSlice_Callback.res#L34-L43)
decodes the payload out of `raw` and drops the rest before calling `project`.

The ReadModel path never had this problem: `Projection.MappingImpl.project`
takes `Message.event'<'id, 'event> = {id, meta, event}`
([`Message.res:85-89`](../../reventless/spec/src/types/Message.res#L85-L89)),
so a mapping can project `meta.time` into its state today.

**Consequences of the gap:**

- No DCB-backed view can carry a `registeredAt`/`placedAt`/`shippedAt`
  timestamp without putting one in the *event payload* — a modelling
  regression that has to be repeated in every example and every user's domain.
  The producer already stamped the time; asking the command author to stamp it
  again is asking them to duplicate framework state into their domain events.
- No DCB-backed view can project the acting user, so audit-flavoured
  projections ("approved by bob at …") are ReadModel-only for no principled
  reason.
- Downstream, this is what keeps every date-axis AutoUI component dark:
  CalendarView, TimelineView-as-mode, AreaChart trends and DateHeatmap all key
  off a date field that DCB views structurally cannot produce.

## Scope

| Capability | In | Out |
| --- | --- | --- |
| `meta` + `recordedAt` reaching StateViewSlice projections | ✅ | |
| Migration of every in-repo projection implementation | ✅ | |
| Verifying `format: "date-time"` survives into the plugin structure | ✅ | |
| Changing ReadModel `Projection.MappingImpl` (already correct) | | ✅ |
| Exposing the envelope to aggregate deciders / command handlers | | ✅ |
| New AutoUI components consuming the resulting date fields | | ✅ (UI repo) |

---

## Decision

Introduce a **named envelope type** in the spec rather than reusing
`Message.event'`. A DCB slice is identified by tags, not by a single aggregate
id, so `event'`'s `id` field does not fit and would have to be faked:

```rescript
type consumed<'e> = {
  event: 'e,
  meta: Message.meta,
  recordedAt: string,
}

module type Projection = {
  module Spec: Spec
  let project: consumed<Spec.consumedEvent> => array<Projection.action<string, Spec.state>>
  let moduleUrl: string
}
```

This is a **breaking change to a published module type**. Accepted
deliberately: the alternative is carrying timestamps in event payloads forever,
in every example and every downstream domain, and the migration is a one-line
destructure per implementation.

Rejected alternatives:

- **An optional second member** (`projectWithMeta`) — ReScript module types
  have no optional members, so this would mean two module types and a
  branch in every builder.
- **Threading meta through a mutable context** — invisible in the signature,
  untestable, and it makes a pure function stop being pure.
- **Timestamps in event payloads, per example** — what this plan exists to
  avoid.

---

## Phase 1 — Spec + callback

1. Add `consumed<'e>` to `reventless/spec/src/components/StateViewSlice.res`
   and change the `Projection` module type's `project` signature.
2. `StateViewSlice_Callback.res` — `raw` is already in scope at the call site
   ([lines 34-43](../../reventless/core/src/components/StateViewSlice/StateViewSlice_Callback.res#L34-L43));
   construct `{event, meta: raw.meta, recordedAt: raw.recordedAt}` instead of
   passing the bare decoded event. No other call-site change: the builders
   (`core`, `local`, `aws`, `aws/_Stream`) reference the module type, not the
   function's argument shape.

## Phase 2 — Migrate implementations

Each becomes `let project = ({event}) => switch event {` — the body is
untouched. Scope check across the repo (StateViewSlice projections only;
ReadModel mappings are unaffected):

- `examples/online-shop-hybrid/` — 5 (`Categories`, `Products`,
  `ProductDemand`, `Orders`, `AvailableProducts`)
- `examples/online-shop-dcb/` — 6
- `reventless/core/tests/plugin/StateViewSlice/` — `PsOrdersView`,
  `PsCustomersView`, `PsAvailableProductsView`, `PsAnnotatedView`, plus
  `PluginStructureTest`
- `reventless/core/src/admin/UiFragmentRegistry/StateViewSlice/UiFragments_Projection.res`
- `reventless/local/tests/` fixtures (`StateViewSliceFixtures`,
  `StateViewSliceSubIdFixtures`) and any GWT test constructing projection
  input directly

Also update the docs pages that show a `project` signature under
`packages/doc/docs/` — the component docs and the DCB pages both quote it.

**This phase must land in the same commit as Phase 1**; a partial migration
does not compile.

## Phase 3 — Verify the date-time format actually reaches consumers

A timestamp string alone buys nothing downstream: the AutoUI date heuristics
are format-first, and **nothing in either repo currently emits
`format: "date-time"`** (the one existing timestamp pair, core's
`UiFragments.registeredAt`/`updatedAt`, is a plain `string`).

sury does emit the format from its `Datetime` refinement, so a state field
annotated `@s.matches(S.datetime(S.string))` should carry `format` through
`SuryToJsonSchema` into the plugin structure. That spelling is **inferred** from
the `@s.matches(Reventless.DcbTag.string)` precedent and needs one compile-and-
inspect check before anything is planned around it. If it does not survive,
this phase turns into a `SuryToJsonSchema` fix and stays in scope.

## Phase 4 — Use it in the hybrid example

`Orders.placedAt` / `shippedAt` projected from `meta.time`, with the datetime
refinement from Phase 3 on the state field. Deliberately the *only* example
change here — proving the path end-to-end without turning the tutorial spine
into a feature zoo.

---

## Acceptance

- Every example and test projection compiles; GWT tests pass with unchanged
  behaviour (the envelope is additive to what the body sees).
- `Orders` exposes a field with `format: "date-time"` in its plugin structure,
  verified by inspecting the generated structure, not by inference.
- Downstream check on the UI side: CalendarView is offered as a toggle on the
  Orders list, with no hints.
  **Not** the Calendar *canvas page* — `Orders` is a StateViewSlice, and canvas
  grouping currently iterates read models only. That is tracked as **B6** with
  the UI-side blockers; with B6 landed, the page appears too. Verify against whichever of the two is
  in place, and don't read a missing Calendar page as a failure of this plan.

## Risks

- **Breaking published module type.** Must land as one commit across spec,
  core, examples, tests and docs; version accordingly.
- **Live schema change.** Phase 4 adds fields to a deployed view, and CI
  deploys this example — the alpha EventLog wants a wipe rather than migration
  code.
- **Phase 3 may be the real work.** If the sury refinement does not survive
  `SuryToJsonSchema`, the format plumbing is a larger job than the signature
  change. Do Phase 3's compile check early — it is cheap and it re-scopes the
  plan if it fails.
- **`recordedAt` vs `meta.time` will get confused.** They differ (storage time
  vs producer time) and projections will pick the wrong one. Document the
  distinction on `consumed<'e>` itself, where the author is looking.
