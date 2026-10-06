# Plan: a command acts only on what the caller owns

**Date:** 2026-09-30<br/>
**Status:** Steps 1–5 built and tested in-process (2026-10-01). Steps 4 and 6
still need a deployed stack: the [§7](#7--state-of-the-prerequisite-plan) prerequisite acceptance and this plan's own
acceptance have not run. See [§11](#11--progress-2026-10-01).<br/>
**Relates to:** `done/owner-scoped-identity-and-reads.md` (the feature this
completes: it stamps an owner on the way in and scopes reads on the way out),
`owner-enforcement-gaps-on-appsync.md` (the two AppSync-only gaps in that
feature, and the lesson [§5](#5--what-a-refused-command-answers) below is built on), `appsync-refusal-vocabulary.md`
(what a refusal says), `Backlog/denied-query-returns-empty.md`.

**Goal.** A slice can state which field of its history names the owner of the
thing a command acts on, and the framework then refuses a command from a caller
who is not that owner, before `decide` runs. Exempt callers keep acting on
anyone's behalf. One declaration, enforced server-side, on every command path.

**Non-goal.** Anything beyond *this field equals this caller*. Team ownership,
delegation and grants stay with the ABAC package, exactly as
`owner-scoped-identity-and-reads.md` [§8](done/owner-scoped-identity-and-reads.md#8--what-this-does-not-do) draws the line.

---

## §1 — The gap, in the example that shows it

`online-shop-hybrid` enforces `@owner` in two places today:

- **writes that create:** `PlaceOrder` marks `@owner customerId`, and
  `makeGenerateCommand` overwrites it with the caller's id, so an order is always
  recorded as the caller's;
- **reads:** `Orders` marks `@owner customerId` on its state, so a shopper lists
  and fetches only their own orders, while an elevated caller sees all of them.

**Writes that act on something existing are not covered.** `CancelOrder` carries
only `{orderId}`. Its decision checks the order's lifecycle and never learns who
placed it, so any identified caller who has an order's id can cancel it. The read
side hides the order from them, and the write side lets them act on it anyway: a
caller who cannot *see* a row can still *change* it.

**Where stamping alone is already enough.** `NotificationPreferences` marks
`@owner recipientId` on `Subscribe` and `Unsubscribe`, and `recipientId` is the
field the slice is keyed by. Overwriting it with the caller's id means the
command can only ever address the caller's own partition: stamping *is* the
ownership check. The gap exists only when a slice is keyed by something other
than its owner (an order by `orderId`) and ownership is a fact recorded in the
history. That is the case this plan is for, and it is the common one.

## §2 — Why a specification cannot close it alone

The rule can be written in a spec today:

1. mark `@owner customerId` on `CancelOrder`, so the caller's id is stamped in;
2. add `customerId` to the `OrderPlaced` the slice consumes;
3. in `decide`, refuse when the two differ.

It works for a shopper and fails in two ways that make it the wrong place:

- **It cannot tell an exempt caller from an owner.** An elevated caller is not
  stamped, and keeps the value it sent. To cancel on a customer's behalf, an
  operator would have to send that customer's id, and `decide` has no way to know
  whether the id it sees was stamped or sent. The exemption rule would leak into
  every spec as a convention.
- **It fails open, one slice at a time.** Every slice that acts on an owned thing
  would have to remember the three steps. A slice that forgets is silently open,
  which is the failure mode `owner-scoped-identity-and-reads.md` was written to
  remove from reads.

## §3 — The two halves of the answer live in different places

Deciding "may this caller act on this order" needs two facts:

- **Who the caller is, classified.** `OwnerScope.resolve` answers
  `Owned({userId}) | Elevated | System | Unidentified`. It needs the full
  `Identity.t`, groups included, and that exists only where the command is
  generated (`CommandGenerator_Callback.makeGenerateCommand`, on both transports).
- **Who owns the order.** That is known only after the handler has read the
  order's events, just before `Behavior.decide`
  (`StateChangeSlice_Callback.res`, the `decide` call near `:360`; the aggregate
  equivalent in `Aggregate_Callback.res`; on AWS, `buildSliceHandler` in
  `DcbCommandTopicEntryPoint_Ops.res`).

What travels between them today is the envelope `Message.meta`, which carries
`user?: string` and no groups. So one of the two facts has to move.

**Options.**

- **A. Carry the classification on the command (recommended).**
  `makeGenerateCommand` already resolves the caller for stamping; it writes the
  result into the envelope as a framework-owned claim (`Owned(userId)` or
  `Exempt`), overwriting anything the payload sent. The handler compares the
  claim with the owner it folds, before `decide`. `decide` stays pure, and one
  classifier (`OwnerScope.resolve`) answers for reads, for stamping and now for
  acting, which is the property the read plan insisted on.
- **B. Check at the resolver against the owner-scoped view.** Before publishing,
  read the view row by id with the caller's scope; since the by-id fix in
  `owner-enforcement-gaps-on-appsync.md`, a foreign row reads as `null`.
  Rejected: it couples a command to a view that need not exist, and a view lags
  the log, so a caller would be refused on their own order until it projects.
  Two sources of truth for one rule.
- **C. Hand the caller to `decide`.** Rejected for the reasons in [§2](#2--why-a-specification-cannot-close-it-alone): every spec
  re-implements the comparison and the exemption, and every scenario has to name
  a caller. Aggregates already receive `meta.user` in their context, which is
  this option half-built; it does not carry the classification either.

**The claim's trust model is the one `@authorize` already has.** It is written
only by `makeGenerateCommand`. A command that reaches a handler by another route
(an automation dispatching a follow-up, a direct invocation) carries no claim and
is treated as `System`, just as those routes bypass `@authorize` today. That is a
statement of the existing model, not a new hole, but it must be written into the
code where the claim is read, and a claim present on a command that did *not*
come through the generator must be impossible to construct from outside.

## §4 — How a slice declares whose thing it acts on

Reuse the marker, on the consumed event:

```rescript
@schema
type consumedEvent =
  | OrderPlaced({@owner customerId: CustomerId.t, productIds: array<CatalogSpec.ProductId.t>})
  | OrderShipped
  | OrderCancelled
  | OrderReopened
```

Meaning: *the value of this field, in the history this command is decided on,
names the owner of what the command acts on.* No component marks a consumed
event `@owner` today; step 1 confirms nothing reads the marker there, so giving
it this meaning changes no existing behaviour.

**Scope of the fold.** The owner is taken only from events in the command's own
partition: the inferred DCB partition for a slice (`DcbScopeInference`), the
stream for an aggregate. A slice that also reads cross-partition events (a
catalog's products) must not have those events consulted for ownership.

**Rules, evaluated before `decide`:**

| Slice marks an owner | History has an owner | Caller | Result |
| --- | --- | --- | --- |
| no | n/a | any | unchanged (today's behaviour) |
| yes | no (nothing created yet) | any identified | allowed; a creating command stamps its own owner |
| yes | yes, equal to the caller | `Owned` | allowed |
| yes | yes, different | `Owned` | **refused**, `decide` does not run |
| yes | any | `Elevated` / `System` | allowed |
| yes | any | `Unidentified` | refused, as stamping already does |
| yes | two different values | any | refused and logged as a data defect; never pick one |

## §5 — What a refused command answers

**Refuse explicitly, with the `@authorize` refusal's shape**, aligned with
whatever `appsync-refusal-vocabulary.md` settles.

The obvious alternative is to decide as if the history were empty, mirroring the
by-id read that answers `null` for a foreign row so as not to confirm the row
exists. **For commands that is dangerous.** An empty history is a *creation*
context: a caller who guesses another owner's id and sends a creating command
would be decided as creating something new, and would write a second creation
event into someone else's partition. The read side can afford "as if absent"
because a read changes nothing.

The cost is honest and should be written down: a refusal confirms that the id
exists. Ids generated for new rows are random UUIDs, which bounds that, and the
tension with the read side's `null` is deliberate rather than an oversight.

## §6 — Every command path, and the lesson from the AppSync gaps

`owner-enforcement-gaps-on-appsync.md` found stamping silently off on the
AppSync DCB path because the generator there was handed a permissive `S.json`
schema, which answers "no owner fields" for every command. Each call site was
individually correct about the schema it was given. The same trap applies here
twice over:

- the handler must read the marker from the slice's **real** `consumedEvent`
  schema; a permissive stand-in makes every slice look unmarked and the check
  fails open;
- the claim must survive every hop between generator and handler (in-process
  call, topic, queue, Lambda event), and a hop that drops it must fail closed for
  a marked slice, never fall back to `System`.

The paths:

| Path | Generator | Handler |
| --- | --- | --- |
| DCB, in-process | `Dcb_Builder` per slice | `StateChangeSlice_Callback` |
| DCB, AppSync topic | `Dcb_Builder` topic / `DcbCommandTopicEntryPoint` | `DcbCommandTopicEntryPoint_Ops.buildSliceHandler` |
| Aggregate, in-process | aggregate generator | `Aggregate_Callback` |
| Aggregate, Lambda | aggregate generator | `AggregateEntryPoint` |

**Test as a conformance table, not per path**, extending the one the AppSync
stamping fix introduced: rows of (caller class, recorded owner, command) run
against every path, failing if any path is handed a schema or an envelope that
answers differently.

**Inherited dependency.** Classification needs the exempt-group list wherever the
generator runs. `owner-scoped-identity-and-reads.md` records that the AWS runtime
builder must pass `REVENTLESS_ELEVATED_GROUPS` to every Lambda; confirm that has
landed before the AWS half of this plan is accepted, or an operator acting on a
customer's behalf will be refused.

## §7 — State of the prerequisite plan

Both fixes in `owner-enforcement-gaps-on-appsync.md` are released: the DCB
stamping fix (`6edbdf468`) and the by-key read fix (`8232fd4c09`) shipped in
`@reventlessdev/reventless-aws` 3.0.0-alpha.306. Its own acceptance, run against
a deployed stack, is not recorded. This plan builds directly on AppSync stamping
being correct, so that acceptance should run and be recorded **before** step 4
below, not after.

## §8 — What this does not do

- **It is not ABAC**, for the reasons the read plan gives.
- **It does not scope subscriptions or event history**, the known gap the read
  plan names; nothing here changes it.
- **It does not guard automation.** A command an automation dispatches is
  `System` by construction ([§3](#3--the-two-halves-of-the-answer-live-in-different-places)). An automation that acts for a user is trusted to
  have been triggered by something that was itself checked.
- **It does not check references.** A command that *names* another owner's thing
  in a field (not its partition) is not covered; that is a reference-level rule
  and belongs with ABAC.

## §9 — Order of work

1. **Survey.** Confirm no code reads `@owner` from a consumed-event schema. List
   every example and trait command that acts on an existing partition whose
   history records an owner, and mark which are already safe because the owner is
   the partition key ([§1](#1--the-gap-in-the-example-that-shows-it)).
2. **The claim, in-process.** `makeGenerateCommand` writes the classification
   into the envelope, overwriting anything sent; unit tests for each caller class
   and for a payload that tries to forge it.
3. **The guard, in-process.** Evaluate [§4](#4--how-a-slice-declares-whose-thing-it-acts-on)'s table in `StateChangeSlice_Callback`
   and `Aggregate_Callback` before `decide`, reading the marker from the real
   schema. Conformance table green in-process.
4. **AWS.** After the prerequisite acceptance ([§7](#7--state-of-the-prerequisite-plan)): the claim through the topic
   and Lambda hops, the guard in both Lambda handlers, the exempt-group
   dependency ([§6](#6--every-command-path-and-the-lesson-from-the-appsync-gaps)). Conformance table green on every path.
5. **Example.** `CancelOrder` marks `@owner customerId` on its consumed
   `OrderPlaced`. Decide whether GWT scenarios gain a way to state the caller, or
   whether the guard is pinned only by the framework's conformance table (open
   question 2).
6. **Acceptance, against a deployed stack.**
   1. A shopper cancels their own order: accepted.
   2. A shopper cancels another shopper's order: refused, and the order's
      history is unchanged.
   3. An operator cancels another shopper's order: accepted.
   4. Placing a new order is unaffected.
   5. An automation acting on an order (auto-shipping) is unaffected.
   6. A client that sends its own classification claim is ignored: the stored
      outcome matches the caller's real class.

## §10 — Open questions

1. **Where the claim lives in the envelope.** A typed optional field on
   `Message.meta` is explicit and schema-checked; a reserved key in `headers` needs
   no schema change but is easier to forge by accident. Recommendation: the typed
   field.
2. **GWT.** Whether scenarios get an optional caller step (`->asCaller(...)`) so an
   example can pin its ownership rule next to its behaviour, or whether that stays
   a framework concern tested once.
3. **Refusal wording**, pending `appsync-refusal-vocabulary.md`.

## §11 — Progress (2026-10-01)

In plain words: the generator now writes who the caller is onto every command,
and both command handlers read the owner out of the history and refuse a
non-owner before `decide` runs. `CancelOrder` in the hybrid example uses it.
What is missing is proof on a deployed stack.

**Step 1, survey.**

- Nothing read `@owner` from a consumed-event or aggregate-event schema before
  this change. The PPX already accepted the marker there, because it transforms
  every type declaration in a spec file.
- `online-shop-hybrid` is the only example or trait using `@owner`. Of its
  commands that act on an existing partition:
  - `CancelOrder` was open. It is now marked.
  - `ShipOrder` is left unmarked because marking it would change nothing. Its
    `@authorize` admits only `Admin` and `Fulfilment`, and the example lists
    both as elevated (`Storefront.elevatedGroups`), so every caller who passes
    `@authorize` is exempt anyway. A deployment that kept `Fulfilment` but took
    it off the elevated list would need to decide again: marked, its staff could
    no longer ship other customers' orders.
  - `ReopenOrder` is `@noApi`, so only internal routes reach it.
  - `Subscribe` and `Unsubscribe` (`NotificationPreferences`) were already safe,
    because the owner field is the partition key.
  - The `Customer` aggregate's `UpdateEmail` and the address commands act on a
    customer whose history records **no** owner, so this mechanism cannot cover
    them. That is a separate gap: the customer record would first have to state
    who it belongs to.

**Step 2, the claim.** `Message.meta.callerClaim?: CallerClaim.t`, with the cases
`Owned({userId}) | Exempt | Unidentified`. It is a typed field (open question 1).
`makeGenerateCommand` classifies the caller once, uses that classification for
the stamp and for the claim, and writes the claim on every command, including
commands that record no owner and commands built by the permissive `S.json`
generator. `deriveMeta` does not copy the claim, so an event, or an automation's
follow-up command, never carries the claim of the command that caused it.

**Step 3, the guard.** `OwnerScope.decideActing` implements [§4](#4--how-a-slice-declares-whose-thing-it-acts-on)'s table, and
`CommandTopic_Helpers.ownershipRefusal` turns its answer into the refusal both
handlers report. Two rules were added while building it:

- A partition the handler cannot name refuses an owned caller
  (`OwnerUnreadable`). Treating it as "no owner yet" would admit everybody.
- Two recorded owners refuse every caller, exempt callers included. This is the
  table's "any" taken literally.

The DCB handler keeps only owners whose event carries the command's partition
value. Both handlers keep the folded owners in their in-process caches. An
aggregate that marks an owner skips persisted snapshots, because a snapshot
holds the state but not the owner. A refusal is `CommandRejected` with
`errorCode: "Forbidden"`, the code an `@authorize` refusal uses (open question
3, pending `appsync-refusal-vocabulary.md`), with the new outcome cause
`AccessRefusal`.

**Step 4, AWS.** No AWS-specific code was needed:
`DcbCommandTopicEntryPoint_Ops.buildSliceHandler` and `AggregateEntryPoint_Ops`
both run the core callbacks, and every hop encodes `meta` through `metaSchema`.
The elevated-groups dependency in [§6](#6--every-command-path-and-the-lesson-from-the-appsync-gaps) has landed: `Util_OwnerScopeEnv` puts
`REVENTLESS_ELEVATED_GROUPS` into every runtime built through
`RuntimeEnvironment_Lambda`. The deployed half of this step is still open.

**Step 5, example.** `CancelOrder` marks `@owner customerId` on its consumed
`OrderPlaced`. Open question 2 is answered both ways:

- The framework's conformance table,
  `reventless/core/tests/commandgenerator/OwnerActingTest.res`, runs every
  caller class through the generator, both envelope encodings (inline and
  queued) and both handlers. It also covers the cross-partition, warm-cache,
  conflicting-owner, unnameable-partition, same-batch and snapshot cases.
  Disabling the guard fails 13 of its 34 tests. Counting owners from every
  partition fails the cross-partition test.
- The GWT DSL gained `asCaller(Caller.owner(id) | Caller.operator |
  Caller.anonymous)` before `whenCmd`, and `thenRefused`. Both run the same
  `decideActing` the handlers run. `CancelOrder_GWT` uses them: the owner and an
  operator may cancel, another customer and an anonymous caller are refused.
  Removing `@owner` from the slice fails exactly the two refusal scenarios.
- The PPX records `thenRefused` in the GWT sidecar as its own kind,
  `forbidden`, and the lifecycle harvest leaves those scenarios out. Building
  this exposed an older gap: a bare piped step (`->thenNoEvent`) reached the
  sidecar walk as `|.`(chain, step) and was recorded as an empty `then`. The walk
  now reads it; `thenNoEvent` was harmless (an empty `then` already meant "no
  change"), but an unread `thenRefused` would have counted as an accepted no-op.

**Still open.**

1. The [§7](#7--state-of-the-prerequisite-plan) prerequisite: run and record the acceptance of
   `owner-enforcement-gaps-on-appsync.md` on a deployed stack.
2. Step 6: this plan's acceptance on a deployed stack, items 1–6.
3. The `Customer` gap from the step 1 survey, as its own plan if wanted.
