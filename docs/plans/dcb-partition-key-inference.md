# Plan: Infer the DCB partition key, and drop `@partitionTag` where inference agrees

**Status:** Proposed (2026-09-16)
**Analysis:** [dcb-partition-key-derivation.md](../analysis/dcb-partition-key-derivation.md)
**Reverses:** the "drop `@partitionTag`" won't-do in
[dcb-tag-scope-inference.md](done/dcb-tag-scope-inference.md) (Phase 4b, Part B), for
the slices where inference and annotation provably agree. The annotation stays where
inference cannot decide.

---

## In plain words

Every DCB event is filed under **one id**: its *partition key*. A product event is
filed under its `productId`, and an order event under its `orderId`. The partition
key decides three things at once:

- **where the event is stored** (the DynamoDB partition),
- **what a command reads** before it decides (the events filed under the same id),
- **which lock guards the write** (the fence of that id).

A wrong choice doesn't fail loudly. The command reads the wrong pile of events and
decides on incomplete facts. So the choice has to be right, and it has to be the same
everywhere it is made.

Most events carry only one id, so there is nothing to choose. Some carry two:
`ProductAdded` has both `productId` and `categoryId`. Today the developer has to say
which one is the partition with `@partitionTag`, even when the answer is obvious from
the code.

The answer is usually obvious because of **what the slice reads**. `AddProduct` reads
`CategoryAdded` to check that the category exists. That event belongs to another
entity, so `categoryId` is a *reference*, not the product's own id. Take away every
id the slice only mentions as a reference, and one id is left: `productId`.

This plan makes that reasoning the single source of the partition key, for reads,
storage, locks and command routing alike. `@partitionTag` stays for the cases where
reading the code doesn't decide it:

- **Joins.** `RecordProductDemand` links a product and an order. Both ids really
  belong to the slice, and only domain knowledge says demand is counted per product.
- **Two own ids.** `PlaceOrder` carries `orderId` and `customerId`, and reads nothing
  that marks either one as a reference.

When inference and an annotation agree, the annotation is noise, and the examples
drop it. When they disagree, the build fails.

---

## Decisions

1. **Rule C, refined** (see "The rule" below). The analysis's rule C, applied as
   stated, breaks `AddProduct` once its annotation is removed. The refinement applies
   it only where the current rule finds nothing.
2. **One derivation for everything.** The storage partition, the fence, the command
   envelope id and the decision-read scope all come from the same inferred result.
   `derivePartitionTag`'s annotation-only rules and the storage `tags[0]` fallback go
   away.
3. **The partition key is per event type, not per boundary.** This removes the
   positional fallback (analysis F2), and it lets two entities in one plugin
   annotate different keys (F1).
4. **An unresolvable partition fails**, at build, boot and deploy, naming the slice.
   It no longer silently falls back to annotations.
5. **Self-read tie breaker: not adopted.** It would resolve `PlaceOrder`, but it
   silently picks the wrong key for joins like `RecordProductDemand`. Ambiguity stays
   an error that asks for `@partitionTag`.
6. **Cold start fails loudly.** A command-handler Lambda whose partition keys can't
   be worked out refuses to start, instead of carrying on without keys. A Lambda
   hosting no StateChangeSlices skips the derivation. See Phase 3.
7. **Redundant annotations are reported, not rejected.** `check:dcb-scope` fails on a
   redundant `@partitionTag` in this repository's examples. Deploy and boot only log
   it at info level, so applications that still annotate keep working.

---

## The rule

For each slice, in terms of the `*Id` fields on its arms:

1. **Own ids** are the ids on the events the slice writes.
2. **Subtract references.** Remove every id that appears on a consumed arm whose
   event type another slice writes. This is today's rule.
3. **Exactly one id left:** that is the partition.
4. **Nothing left:** apply rule C. Give back an id when every other-slice arm that
   carries it comes from a slice *partitioned by that same id*. Reading your own
   entity's events by its id is identity, not a reference. This is the
   `ChangeProductName` reading `ProductAdded({productId, name})` case.
5. **Several ids left, or none after step 4:** the slice needs `@partitionTag`.
6. **Seeds and cycles.** A slice whose events carry a single id is partitioned by
   it, whatever it reads. An explicit `@partitionTag` is also a seed. Step 4 runs
   to a fixpoint over the boundary. While a producer is still unresolved, an id it
   writes counts as possibly its own. This breaks cycles such as `ShipOrder` ⇄
   `CancelOrder`, each reading the other's event. The result counts only when the
   whole boundary resolves and a further pass changes nothing, so this optimism never
   decides the final answer.

**Why step 4 only fires on "nothing left".** Rule C applied everywhere treats
`CategoryAdded({categoryId})` as same-entity evidence for `AddProduct`, because
`AddCategory` is partitioned by `categoryId`. `AddProduct` then has two candidates,
`productId` and `categoryId`, and turns ambiguous. The current subtraction is right
whenever it leaves a result. Rule C is only needed where the subtraction leaves the
slice with no id at all.

### Simulated on the compiled examples (2026-09-16)

The simulation covers 37 slices in 4 plugins, compared against
`examples/*/schema/dcb-scope.json`. "Trap" means every consumed arm from another
slice also names that slice's ids, i.e. the "don't name your own id on a lifecycle
arm" convention is ignored. "Target annotations" means only `PlaceOrder` and
`RecordProductDemand` keep `@partitionTag`.

| Rule | As written, all annotations | As written, target annotations | Trap, target annotations |
|---|---|---|---|
| Current | 37/37 | 37/37 | 12/37 |
| Rule C as stated in the analysis | 37/37 | 36/37 (`AddProduct` ambiguous) | 34/37 |
| **Refined rule (this plan)** | **37/37** | **37/37** | **37/37** |

- **Stored ids don't change.** For every event type in both examples, the key the
  current storage code files the event under (`derivePartitionKey`: the boundary tag,
  else `tags[0]`) equals the producing slice's inferred partition. No table wipe or
  migration is needed.
- **The one-slice view** (the per-slice GWT harness, which sees no siblings) resolves
  every slice as written. In the trap variant it cannot resolve `CancelOrder` and
  `ShipOrder`, because it cannot see who writes `OrderPlaced`. There it reports the
  blocking arm, which is the right message: remove the id from that arm.

---

## Phases

### Phase 1: the refined rule in `DcbScopeInference`

- [`DcbScopeInference.infer`](../../reventless/spec/src/components/DcbScopeInference.res):
  single-id seeding, the fixpoint, and step 4 (only when step 2 leaves nothing).
  Non-convergence or a leftover ambiguity becomes an `ambiguities` entry.
- `partitionBlockers` names only the arms step 4 could not give back.
- `crossPartitionForSlice` and the one-slice path: an unseen producer counts as
  foreign (unchanged).
- Update the module doc's "No fixpoint needed" line.
- Tests in [`DcbScopeInferenceTest.res`](../../reventless/core/tests/dcb/DcbScopeInferenceTest.res):
  - `AddProduct` without a hint resolves to `productId`
  - a lifecycle arm naming the slice's own id resolves
  - the `ShipOrder` ⇄ `CancelOrder` cycle resolves
  - a join without a hint stays ambiguous
  - a produced id owned by another slice is **not** dropped (otherwise
    `RecordProductDemand` would flip to `orderId`)
  - non-convergence is reported as an ambiguity
- **Done when** `pnpm run check:dcb-scope` passes with the goldens unchanged.

### Phase 2: check annotations against inference

Beside [`validateScopeVsInference`](../../reventless/spec/src/components/DcbValidation.res#L461):

- **Contradiction (error).** A `@partitionTag` naming an id that the slice only
  mentions as a reference, or that differs from what inference derives unaided when
  inference does resolve.
- **Redundant (report).** Inference, run with the hint removed, reaches the same id.
- `Dcb_Builder` logs contradictions at error level and throws, and logs redundancies
  at info level. `check:dcb-scope` fails on both. `Flow_GWT.thenBoundaryScopeResolves`
  fails on contradictions.

### Phase 3: one derivation for storage, fence and envelope id

Replace the annotation-only `derivePartitionTag` with a derivation built on Phase 1.
It returns, per boundary:

- `partitionBySlice`, as today;
- `partitionKeyByEventType`: the event type mapped to its producing slice's
  partition key;
- `Composite(spec)` where `@compositePartitionTag` is used (unchanged, still
  explicit).

It **throws** on an ambiguity, naming the slice and the blocking arms.

Call sites (all from the analysis's "Where it runs" table):

| Call site | Change |
|---|---|
| [`Dcb_Builder.res:256`](../../reventless/core/src/components/Dcb/Dcb_Builder.res#L256) | uses the new derivation, and threads the result to the event log and to each slice and command generator it builds |
| [`StateChangeSlice_Callback.res:78`](../../reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L78) | receives the slice's partition from the builder instead of deriving it alone |
| [`CommandGenerator_Callback.res:171`](../../reventless/core/src/components/CommandGenerator/CommandGenerator_Callback.res#L171) | the envelope id is the value of the **handling slice's** partition field on the command (`Dcb_Builder` builds these, so the boundary is at hand). A command without that field keeps today's `""` |
| [`ExtensionMapping.res:226`](../../reventless/infra/src/types/ExtensionMapping.res#L226) | the `Delegate` is a slice of the same plugin; the generated `Plugin.res` passes the plugin's partition map. Outside a generated root, it falls back to one-slice inference and throws if unresolved |
| [`DcbCommandTopicEntryPoint_Ops.res:64`](../../reventless/aws/src/adapter/Runtime/DcbCommandTopicEntryPoint_Ops.res#L64) | the same derivation, with no `catch → None`; see "Cold start fails loudly" below |
| [`DcbEventLogStorage_DynamoDb_Runtime.res`](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res) `derivePartitionKey`, `eventPartitionTags` | look up the key by `event.eventType`. An event type missing from the map throws; there is no `tags[0]` fallback |
| [`PgChangeFeedRelay_Runtime.res`](../../reventless/aws/src/adapter/Postgres/PgChangeFeedRelay_Runtime.res) and `DcbBackend` | carry the per-event-type map in `HANDLER_CONFIG`, so relay ids match the DynamoDB path |
| [`Behavior_GWT.res`](../../reventless/gwt/src/Behavior_GWT.res) / [`Flow_GWT.res`](../../reventless/gwt/src/Flow_GWT.res) | one-slice and boundary views of the same function |

The "only one `@partitionTag` per boundary" error goes away, because two entities in
one plugin may now each name their own key.

#### Cold start fails loudly

**In plain words.** A command-handler Lambda works out the partition keys again when
it starts. Today, if that fails, it quietly carries on with "no partition key", and
storage then files each event under the first id declared on it. That is right by
luck for simple keys and wrong for composite keys: the event lands under one member,
and the locks break up.

The Lambda loads the same full slice list as deploy, so on the same code this step
cannot fail where deploy succeeded. Two cases remain:

- **The Lambda hosts no StateChangeSlices**, only inbound translations
  (`stateChangeSliceModules: []`). There are no events, so there is no key to work
  out and nothing is appended. This is the one legitimate use of today's catch.
- **The framework in the Lambda layer differs from the one used at deploy.** The
  layer is built and versioned separately, so it can be older or newer. The catch
  hides this.

**Change.**

- With no slices, skip the derivation and use an empty partition map. Storage is
  never asked to append.
- Otherwise, a failed derivation is logged at error level, naming the slice and the
  blocking arms, and **rethrown**. The Lambda refuses to start, every invocation
  reports the same message, and messages go to the DLQ instead of being processed
  with the wrong keys.
- **Keep the message intact.** Startup runs when the module loads
  (`initPromise` in `DcbCommandTopicEntryPoint.mjs`), before any invocation waits
  on it, so a failure starts out as a promise rejection nobody is handling yet. The
  Lambda runtime may report that as a generic `Runtime.UnhandledPromiseRejection`
  and restart, losing our message. So log the reason where it is detected, and
  attach a catch to the startup promise so each invocation rethrows the same clear
  error.
- Correct the "untagged fences" comment: the old fallback meant "first declared id
  wins".

**How it shows up.** Deploy stays green, because creating a Lambda does not run its
startup code. The first command after deploy fails, and so does every one after it,
until a fix is deployed:

- **Sync mutation:** a GraphQL error instead of `CommandAccepted` / `CommandRejected`.
- **Async mutation and commands from extensions:** `CommandPending`, then no
  outcome. SQS retries the message 5 times, then moves it to the FIFO dead-letter
  queue.
- **Inbound translation on the same Lambda:** fails too, since it waits on the same
  startup.
- **Where to look:** the error line in the logs of `<Plugin>DcbCmdHandler` /
  `<Plugin>DcbAsyncCmdHandler`, naming the slice. With monitoring on, the Lambda's
  `Errors` alarm fires, and the dead-letter sink's alarm fires once async messages
  give up.

**Tests.**

- `buildHandlersForConfig` with no slices starts, and inbound translation still
  routes ([`DcbInboundTranslationRoutingTest`](../../reventless/aws/tests/DcbInboundTranslationRoutingTest.res)).
- With a slice whose partition cannot be resolved, it rejects with the slice's name
  in the message.
- Calling `handler` after a failed startup rethrows that same error on every call,
  and the rejection is never left unhandled.

The envelope-id catch in `CommandGenerator_Callback` (a permissive `S.json` command
schema with no tagged fields falls back to `""`) is a separate case. It stays as it
is.

**Verification:**

- `check:dcb-scope` also goldens `partitionKeyByEventType`. Its first write must
  equal the ids the current storage code produces; the simulation shows it does.
- Unit tests on `derivePartitionKey` / `buildConditionalTransactItems` with the map,
  including a multi-tag event whose key is not the first declared field.
- Run the existing DynamoDB atomic-append integration test. Local backends ignore
  partitioning (analysis F3), so this is the only test that observes it.

### Phase 4: remove redundant annotations, and explain it in the docs

**Remove** `@partitionTag`, together with the "@partitionTag picks the storage
partition" comments above it:

| File | Where |
|---|---|
| [hybrid `AddProduct.res`](../../examples/online-shop-hybrid/catalog/src/Product/StateChange/AddProduct.res) | command and event |
| [hybrid `ShipOrder.res`](../../examples/online-shop-hybrid/ordering/src/Order/StateChange/ShipOrder.res) | event |
| [dcb `CancelOrder.res`](../../examples/online-shop-dcb/ordering/src/Order/StateChange/CancelOrder.res) | event |

**Keep**, and reword their comments to say *why* inference cannot decide:

- `PlaceOrder`, in both examples (two own ids)
- `RecordProductDemand`, in both examples (join)

Core test fixtures that exercise the annotation itself stay annotated.

**Docs** (plain words, built on "In plain words" above):

- [`dcb-usage.md`](../../packages/doc/docs-app/dcb-usage.md) "Event Log Partitioning":
  - rewrite "How partitioning works" (its "each event's first tag determines its
    partition key" is already inaccurate) and "Partition tag derivation" as the
    three-step story: own ids, minus references, what is left
  - rewrite "Cross-entity reference reads" without "Inferring the storage partition
    is planned; until then, mark it"
  - add a short "When you still need `@partitionTag`" with the join and two-own-ids
    examples, and the error message the reader will see
- [`reventless-ppx.md`](../../packages/doc/docs-app/reventless-ppx.md) `@partitionTag`
  row: "Required when inference is ambiguous", not "Required when a variant has
  multiple `*Id` fields"
- [`statechangeslice.md`](../../packages/doc/docs-app/components/statechangeslice.md),
  [`platform-and-plugin-guide.md`](../../packages/doc/docs-app/platform-and-plugin-guide.md),
  [`dcbeventlog.md`](../../packages/doc/docs-framework/runtime-components/dcbeventlog.md),
  [`dcb-consistency-checks.md`](../../packages/doc/docs-framework/internals/dcb-consistency-checks.md),
  and the `dcb-based` / `hybrid-based` tutorials: align examples and wording
- [`.claude/rules/app-developer.md`](../../.claude/rules/app-developer.md) DCB tag
  inference paragraph: drop "`@partitionTag` is still required on multi-`*Id` events
  (storage partition is not yet inferred)"
- Skills: `rescript/references/sury-ppx-patterns.md`,
  `reventless-app/references/cross-plugin-patterns.md`
- [dcb-tag-scope-inference.md](done/dcb-tag-scope-inference.md): a one-line pointer
  from Part B to this plan

**Final commit:** `git mv` this plan to `done/`, and the analysis to
`docs/analysis/done/`.

---

## Out of scope

- **Compile-time detection in `generate-plugin`** (analysis F7). It needs the
  source-side shape adapter.
- **Chapter-vs-partition report** (analysis F6).
- **A startup check at deploy.** After deploy, call each DCB command Lambda once
  with a harmless "are you ready?" request, and fail the deploy if startup failed.
  That would catch a mismatch between the framework in the Lambda layer and the one
  used at deploy before users hit it. Add it only if such a mismatch is actually
  seen; until then, the loud startup failure above is enough.
- **Inferring `@compositePartitionTag`.** A key built from several fields is a design
  choice, not something the code reveals.
