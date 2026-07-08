# Plan: Composite query-clause fence contention (residual after the composite-fence collapse)

**Status:** DONE 2026-07-09 — root cause was **not** the composite query-clause fence
this plan hypothesised. It is the `originatorSlice` provenance tag (appended to every DCB
event by [`StateChangeSlice_Callback.encodeEvent`](../../../reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res))
leaking into the DynamoDB `tag_composite` key, so a composite-partition slice can never read
back its own events (every re-sync reads empty → re-emits a create → dies on the create-guard
fence → retries exhausted → read models stay empty). Fixed by **removing `originatorSlice`
entirely** — provenance never belonged in the content-addressed `tags` surface. See
**Resolution** at the bottom, and [docs/analysis/dcb-event-provenance-and-metadata.md](../../analysis/dcb-event-provenance-and-metadata.md)
for the provenance/`meta.service` follow-up.

**Status (original):** Proposed (evidence-gated, opened 2026-07-08) — real-DynamoDB burst trace in hand.
**Builds on:** [done/dcb-composite-fence-residual-burst-contention.md](dcb-composite-fence-residual-burst-contention.md)
(collapsed per-*member* fences to one synthetic composite fence and closed the deployed-Lambda
`partitionTag` wiring gap) and [dcb-fence-scope-alignment.md](../dcb-fence-scope-alignment.md)
(which deferred the composite sentinel as *"only needed if a slice writes a >1-tag event but
queries a subset of those tags, which no current slice does"* — that case now exists).

## Summary

After the composite-fence collapse ships and is threaded into the deployed append path, a
same-boundary **burst of distinct composite entities** still contends to a hot single item
under concurrency. The per-member fences are gone; what remains is **one conditional fence
Update, at transaction item index [1], that conflicts on every append in the burst regardless
of the entity being written.** Root cause is the composite **query-clause** fence: when a
slice's decision read is at a **coarser grain than the appended entity**, the collapsed
composite fence value is low-cardinality and shared across the whole fan-out.

## Live evidence (real DynamoDB, deployed runtime, 2026-07-08)

A fan-out workload appends many per-entity commands into one DCB event log. Each command's
StateChangeSlice has a `@compositePartitionTag` over a 4-member `{a,b,c,d}` and a 5-member
`{a,b,c,d,e}` set (shared low-cardinality prefix `{a,b}`, high-cardinality tail).

- **The collapse is confirmed active:** the table carries synthetic
  `fence#__dcb_composite__:<a>/<b>/<c>/<d>/…` rows that are correctly high-cardinality per
  entity, and the old 3-hot-member cancellation shape `[None, TC, TC, TC, None, None]`
  (three per-member fences) is **gone**.
- **Residual conflict is a single shared item:** the dominant failures are now
  `[None, TransactionConflict, None, None, None, None]` and
  `[None, TC, None, TC, None]` — **item [1] conflicts universally**, with occasional
  same-entity fences at later indices. Burst tally: ~300 retries-exhausted over ~1500
  attempts; the rarer event types in the fan-out never persist (their read models stay
  empty), while the high-frequency ones win enough of the burst to populate.
- **The shared fence is a coarse composite:** among the `__dcb_composite__` rows is one with
  the **entity members empty** — value `<a>/<b>/<c>////` (only the prefix filled). Every
  command in the `<c>` fan-out conditionally bumps this one row. That is item [1].

## Root cause

In `buildConditionalTransactItems`
([`DcbEventLogStorage_DynamoDb_Runtime.res`](../../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res)),
the composite rewrite replaces a multi-tag query clause's tags with a single
`makeCompositeFenceTag(clauseTags, spec)`. The final transaction is
`putItems ++ conditionalUpdates ++ checks ++ bumps`, so item [1] is the first conditional
fence Update — the collapsed composite fence for the slice's **decision clause**.

When the decision clause reads at a coarser grain than the entity being appended (e.g. a
"does this parent already contain child X?" read scoped to the parent, while the append
writes a child-grained entity), `getCompositePartitionKeyValue` produces a value that fills
only the coarse members and leaves the entity-distinguishing members empty. That value is
identical for every distinct child under the same parent → the conditional Update on that
fence serializes the entire same-parent fan-out. Correct entities, correct isolation
intent — but a fence whose cardinality is the *read* grain, not the *write* grain.

This is the `dcb-fence-scope-alignment` "fence-scope = read-scope" invariant reappearing one
level up: the collapse fixed *member* over-fencing on the write (bump) path; the residual is
that a coarse **read** clause legitimately needs a *check* of a broad scope but is being
implemented as a *conditional bump* of a shared fence, which serializes writers that do not
actually conflict.

## Options

1. **Coarse read clause → ConditionCheck, not conditional Update** (extends the Phase-0
   fence-scope alignment to composite clauses). If a clause's composite value is a strict
   prefix of (i.e. coarser than) the appended entity's composite value, the writer must
   *assert* that broad scope's position (read-only `ConditionCheck`, no bump) rather than
   bumping a shared fence. Distinct entities then no longer serialize on the coarse fence;
   genuine conflicts (a concurrent write that actually changes the coarse scope) still fail
   the check. This mirrors the existing single-tag secondary → ConditionCheck rule.
2. **Bump only the finest composite fence.** When a slice touches nested composite grains,
   write the conditional bump only on the entity-grained fence and downgrade coarser
   clauses to checks. Same effect as (1), framed by grain.
3. **Retry-budget backstop (not a fix).** Widen/back-off the append retry or serialize
   per-boundary when a coarse shared fence is unavoidable. Only if (1)/(2) leave a residual.

Recommend **(1)** — it is the direct generalization of the shipped fence-scope rule and
keeps the conditional *bump* set equal to the write grain while preserving the read
assertion. Watch the ABA/stale-read semantics of a prefix ConditionCheck (assert
`lastPosition <= :after` on the coarse fence) so it stays a correct optimistic guard.

## Asks

- Classify each item of one burst append's `TransactWriteItems` in the current runtime and
  confirm item [1] is the coarse composite query-clause fence (value = read grain, members
  beyond the read grain empty).
- Implement option 1: a composite clause coarser than the append entity emits a
  `ConditionCheck` on the coarse composite fence, and the conditional bump set is restricted
  to the entity-grained composite fence.
- Extend the DCB integration burst regression (added by the residual-burst plan) with a
  **nested-grain** case: N distinct child entities sharing a parent, each appended
  concurrently while the slice's decision reads at the parent grain — assert all commit with
  0 (or bounded, converging) retries-exhausted and that the only conditional bump per append
  is the entity-grained `fence#__dcb_composite__` row, with the parent-grained fence written
  at most as a check.

## Acceptance

- A same-parent, distinct-child concurrent burst appends with 0 retries-exhausted (or
  bounded, converging) and all events persist.
- Integration test: nested-grain N-way burst converges; reverting the check/bump split turns
  it red (parent-grained conditional bumps reappear and re-serialize).
- Fence-row scan: distinct child entities carry distinct entity-grained composite fences; the
  parent-grained composite value is not a conditional-bump contention point.

## Resolution (2026-07-09)

**The hypothesised mechanism was refuted; the real one was found by driving the actual
`platform-inspector` slices through the deployed entry point (`DcbCommandTopicEntryPoint.mjs`)
against DynamoDB Local and classifying the transaction (the plan's ask #1).**

**Refutation of the "coarse composite query-clause fence" hypothesis.** With the
`partitionTag` wiring fix ([done/dcb-composite-fence-residual-burst-contention.md](dcb-composite-fence-residual-burst-contention.md))
active, the composite collapse works: every append is **2 items** — a PUT plus one
conditional Update on its **own distinct high-cardinality composite fence**
(`SyncResource → fence#__dcb_composite__:prod/plat/plug//compA//r1`). Distinct entities
never share a fence, so there is no coarse conditional-bump contention point. The 6-item
`[None, TransactionConflict, …]` shape in the live trace is the **pre-collapse per-member**
shape (1 PUT + 5 member fences, low-cardinality members hot) — i.e. the trace predates the
deployed layer carrying the wiring fix. (Also learned: DynamoDB **Local does not model
`TransactionConflict` at all** — a 20-way burst sharing one item commits 20/20 for both a
shared bump and a shared check — so conflict-count acceptance cannot be asserted locally.)

**Actual root cause — `originatorSlice` pollutes `tag_composite`.**
`StateChangeSlice_Callback.encodeEvent` appends a provenance tag
`{key: "originatorSlice", value: <sliceName>}` to **every** stored event's tags. The
DynamoDB adapter's `toItem` computed `tag_composite = compositeTagKey(event.tags)` over
**all** tags, so the stored composite key was
`…#originatorSlice:SyncResource#pluginName:…`. A composite decision **read**
(`queryByCompositeTags`) keys off the **command's entity tags only** (no `originatorSlice`),
so the read key never matched the stored key → **a composite-partition slice could never
read back its own events.** Consequence: every re-sync/update reads empty state, re-emits a
*create*, hits the `after=None` create-guard fence (which already exists), and exhausts
retries → `CommandRejected` → the read models never (re)populate. Single-tag slices are
unaffected (they read the base-table partition `id`, not the composite GSI, and
`derivePartitionKey`/the composite **fence** value both ignore `originatorSlice` because it
is not a `spec.keys` member — verified).

Proof (real slices, DynamoDB Local): a `SyncResource` create stored
`tag_composite = componentName:compA#environment:prod#originatorSlice:SyncResource#platformName:plat#pluginName:plug#resourceName:r1`,
while the read key was
`componentName:compA#environment:prod#platformName:plat#pluginName:plug#resourceName:r1`
— a raw composite-GSI query with the read key returned **0 items**. A re-sync (even after a
3s GSI-settle) read 0 events, re-emitted `ResourceAdded`, and died `retries exhausted`.

**Fix (code-only, no PPX / no republish of ppx).** `originatorSlice` was a *provenance* value
smuggled through the DCB `tags` array (the content-addressed routing surface) purely to feed an
admin subscription field **no consumer reads**. Rather than patch the one symptom, it was
**removed entirely** (provenance never belonged in `tags`):
- `StateChangeSlice_Callback.encodeEvent` no longer appends the `originatorSlice` tag; the
  `readEventId` special-case filter is gone.
- [`toItem`](../../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res)
  computes `tag_composite` over the event's entity tags again — now correct, since no provenance
  tag is present — so the stored composite key is byte-identical to the read key.
- Removed the `originatorSlice: String` field from the event-log subscription schema
  (`Plugin_SubscriptionSchema.res`) and its extraction in `EventLogSubscription_AppSync.res`.
- The producing slice stays derivable from `eventType` (each slice owns its produced event types).
  The follow-up question — whether provenance should become a first-class, uniform `originator`
  across aggregates **and** DCB, and what to do about the overloaded `meta.service` — is analysed
  in [docs/analysis/dcb-event-provenance-and-metadata.md](../../analysis/dcb-event-provenance-and-metadata.md).

**Tests (green).**
- Unit: `DcbEventLogStorage_DynamoDb_RuntimeTest.res` — `toItem` `tag_composite` equals the key a
  composite read builds from the entity tags (`compositeTagKey`).
- Integration (DDB Local, deterministic — no reliance on conflict modelling):
  `DcbCommandTopicEntryPoint_IntegrationTest.res` `composite read-back` — `EpCompositeSlice`
  gains a `TouchResource` command requiring state `Added` (i.e. it must read back its own
  `ResourceAdded`); it commits after the fix and rejected `NotFound` before it. Verified as a
  genuine guard: reintroducing the `originatorSlice`-in-`tag_composite` behaviour turns it red
  (`decide rejected: NotFound`).
- Suites: reventless-core **499/499**, reventless-aws unit **209/209**, DCB integration
  **17/17**; zero build warnings across spec/core/local/aws.

**Deploy note.** Ships via normal publish of reventless-spec/core/aws → Lambda layer rebuild
→ `platform-inspector` redeploy onto the new layer. On alpha, existing composite
`fence#__dcb_composite__:…` rows and events are derived state — a wipe is acceptable (cf.
`memory: prefer wipe over migration in alpha`) if any pre-fix half-written state lingers,
though the fix alone lets re-syncs succeed since it makes reads find prior events.

**Follow-up (out of scope, noted).** The `platform-inspector` boundary derives a **7-key**
composite spec (`SyncExtensionWiring` widens it with `extensionPointName` + `subscriberPlugin`)
with **cross-slice position collisions** (pluginName vs extensionPointName at position 2;
componentName vs subscriberPlugin at position 3), producing sparse interleaved fence/partition
values like `prod/plat/plug//compA//r1`. It does not cause contention (distinct entities →
distinct values) and reads are unaffected (`compositeTagKey` sorts by key), but it is fragile
— slice-processing-order dependent. Track separately if the composite spec derivation should
reject or namespace colliding positions across slices in a boundary.
