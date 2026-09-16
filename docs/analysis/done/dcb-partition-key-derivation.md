# DCB partition key derivation: how a default is chosen when an event carries several ids

**Found:** 2026-09-15, answering "which id becomes the partition tag when nothing is
annotated, and should the first-mentioned id be the default?"
**Status:** Analysis — no code changed. Findings verified against `alpha` (`ac0bdc23f`)
by reading the derivation code, the five annotated example slices, the
`dcb-scope.json` goldens, and probing the compiled `DcbTag` module in node.
**Resolved by:** [`dcb-partition-key-inference.md`](../../plans/done/dcb-partition-key-inference.md)
**Builds on:** [`dcb-tag-scope-inference.md`](../../plans/done/dcb-tag-scope-inference.md)
(the inference design and the decision to keep `@partitionTag`), and
[`dcb-runtime-scope-annotation-drift.md`](../dcb-runtime-scope-annotation-drift.md)
(why every call site must derive scope through the same functions).

## Summary

- There are **two independent derivations** of "the partition". One chooses the
  storage partition and fence (`DcbTag.derivePartitionTag`), and it reads annotations
  only. The other chooses the decision-read scope (`DcbScopeInference.infer`, rule 1),
  and it reads the slice graph. They agree today only because every example is
  annotated consistently.
- **Neither takes the first-mentioned id.** An unannotated multi-id event is an error.
  The one silent default in `derivePartitionTag` is alphabetical, and it applies only
  when no single variant carries more than one tag.
- **A first-mentioned default already exists, one layer down.** On AWS, an event that
  does not carry the boundary's partition tag is stored under its **first declared
  tag** (F2). Nothing warns about it.
- **The storage partition tag is boundary-wide, but the inferred partition is per
  slice** (F1). As a result, two slices in one plugin cannot declare `@partitionTag` on
  different keys, and an unannotated multi-id slice passes the boundary check when some
  *other* slice is annotated.
- Taking the first-mentioned id and printing a warning is **not recommended** (F4). An
  "id shared with consumed events" rule is **not recommended** either (F5): it gets 3
  or 4 of the 5 annotated slices wrong. The current subtraction rule is right about
  references. Its weak point is that it decides foreignness per slice rather than per
  entity (F6).
- Nothing runs at compile time (F7). The earliest whole-boundary gate is
  `check:dcb-scope`.

---

## The two derivations

### A. Storage partition and fence: `derivePartitionTag`

[`DcbTag.res:1450`](../../../reventless/spec/src/components/DcbTag.res#L1450). Its input is
the **produced event schemas** only; the command and consumed events play no part. It
works from the tag flags the PPX put on the schema, so a field counts as tagged after
auto-tagging of `*Id`, `@dcbTag` and `@noTag`.

| Situation (across all schemas passed in) | Result |
|---|---|
| No tagged fields | throws "DCB spec has no tagged fields" ([:1519](../../../reventless/spec/src/components/DcbTag.res#L1519)) |
| Exactly one tagged field | that field |
| Several tagged fields, but **no variant** has more than one | **alphabetically first** field ([:1553](../../../reventless/spec/src/components/DcbTag.res#L1553)) |
| Some variant has more than one tagged field, and exactly one `@partitionTag` exists | that field |
| …and no `@partitionTag` exists | throws, naming slice, variants and file ([:1543](../../../reventless/spec/src/components/DcbTag.res#L1543)) |
| …and more than one distinct `@partitionTag` exists | throws "only one is allowed" ([:1549](../../../reventless/spec/src/components/DcbTag.res#L1549)) |
| `@compositePartitionTag` mixed with `@partitionTag`, or fewer than 2 members | throws |

The result is written into the DcbEventLog as `~partitionTag`, and on AWS it selects
the base-table `id` of every stored event:
[`derivePartitionKey`, `DcbEventLogStorage_DynamoDb_Runtime.res:64`](../../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L64).
The in-memory and SQLite backends ignore it
([`_InMemory.res:53`](../../../reventless/local/src/adapter/DcbEventLog/DcbEventLogStorage_InMemory.res#L53),
[`_Sqlite.res:164`](../../../reventless/local/src/adapter/DcbEventLog/DcbEventLogStorage_Sqlite.res#L164)).

### B. Decision-read scope: `DcbScopeInference.infer`, rule 1

[`DcbScopeInference.res:189`](../../../reventless/spec/src/components/DcbScopeInference.res#L189).
Its input is a structural shape built per slice by
[`DcbTag.sliceShapeFromSchemas`](../../../reventless/spec/src/components/DcbTag.res#L1180):
the `*Id` / `*Ids` fields **by name**, regardless of tag flags. Nested record fields are
included, and `*Ids` is singularised.

For each slice:

1. `produced` = the keys on the slice's own `event` arms.
2. `foreign` = the keys on `consumedEvent` arms whose event type **this slice** does not
   produce ([`foreignConsumedKeys`, :124](../../../reventless/spec/src/components/DcbScopeInference.res#L124)).
3. A `@partitionTag` hint that names a produced key wins
   ([:199](../../../reventless/spec/src/components/DcbScopeInference.res#L199)). The hint is
   read only when all of the slice's `@partitionTag`s name one field.
4. Otherwise `produced − foreign` decides:
   - exactly one key left: that key is the partition
   - no keys left: ambiguous, "no own partition key", with the arms that removed the key
     ([`partitionBlockers`](../../../reventless/spec/src/components/DcbScopeInference.res#L152))
   - several keys left: ambiguous, "add @partitionTag"

This never throws. An ambiguity makes
[`deriveEffectiveScope`](../../../reventless/spec/src/components/DcbTag.res#L1251) fall
back to annotations for the **whole boundary**, which is the all-or-nothing blast radius
that `check:dcb-scope` guards.

**Why foreign keys are subtracted.** A slice consumes another producer's event for one
of two reasons: to validate a reference ("does this category exist and is it live?") or
to copy a fact across ("which customer placed this order?"). Either way, the id on that
arm names *another* entity. The slice's own id usually appears on **no** consumed arm at
all, because the decision read is already scoped by the command's tag. An id shared with
a foreign arm is therefore evidence that it is a reference, not evidence of identity.

---

## Where it runs

| When | Call site | Derivation | On failure |
|---|---|---|---|
| Compile time | — (the PPX sees one file and only writes metadata) | none | — |
| Tests | [`Behavior_GWT.res:274`](../../../reventless/gwt/src/Behavior_GWT.res#L274) (one slice), [`Flow_GWT.res:241`](../../../reventless/gwt/src/Flow_GWT.res#L241) (boundary) | B | per-slice tests cannot see the boundary fallback; `thenBoundaryScopeResolves` asserts it |
| CI | [`scripts/check-dcb-scope.mjs`](../../../scripts/check-dcb-scope.mjs) | B, compared with `examples/*/schema/dcb-scope.json` | fails on ambiguity or drift |
| Deploy (Pulumi, incl. preview) and local boot | [`Dcb_Builder.res:256`](../../../reventless/core/src/components/Dcb/Dcb_Builder.res#L256) (A, boundary), [`:391`](../../../reventless/core/src/components/Dcb/Dcb_Builder.res#L391) (B) | A + B | A throws; B only logs (info diff, error on dropped cross-partition keys) |
| Slice builder applied (deploy, boot, cold start) | [`StateChangeSlice_Callback.res:78`](../../../reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L78), applied by [`StateChangeSlice_Builder.res:11`](../../../reventless/core/src/components/StateChangeSlice/StateChangeSlice_Builder.res#L11) | A, **this slice only** | throws, uncaught (the value is used only to log read-event ids) |
| Lambda cold start | [`DcbCommandTopicEntryPoint_Ops.res:50`](../../../reventless/aws/src/adapter/Runtime/DcbCommandTopicEntryPoint_Ops.res#L50) | A + B, boundary | A is **caught → `None`** (untagged fences) |
| Every command without a resolver-supplied id | [`CommandGenerator_Callback.res:171`](../../../reventless/core/src/components/CommandGenerator/CommandGenerator_Callback.res#L171) | A on the **command** schema | caught → envelope id `""` |

---

## Findings

### F1 — One partition tag per boundary, but partitions per slice

`Dcb_Builder` passes **all** of a plugin's produced schemas to `derivePartitionTag` and
gets back one key for the whole event log. Running it on the compiled examples gives:

| Boundary | Storage partition tag | Slices partitioned by something else (golden) |
|---|---|---|
| `online-shop-hybrid/catalog` | `productId` | all `*Category*` slices (`categoryId`) |
| `online-shop-hybrid/ordering` | `orderId` | `EmailVerificationChallenges` (`customerId`), `NotificationPreferences` (`recipientId`), `NotificationSourceClaims` (`sourceId`), `SyncCatalogProduct` (`productId`) |
| `online-shop-dcb/catalog` | `productId` | category slices |
| `online-shop-dcb/ordering` | `orderId` | customer slices, `SyncCatalogProduct` |

Two consequences, both confirmed by probing `derivePartitionTag` with a synthetic slice
added to a real boundary:

1. **An unannotated multi-id slice passes the boundary check.** Adding
   `AddressLinked{customerId, addressId}` with no annotation to hybrid `ordering`
   returns `Simple(orderId)` instead of throwing, because `PlaceOrder`'s `@partitionTag`
   satisfies the "exactly one annotated" arm. The error still surfaces, but only from
   the **per-slice** call in `StateChangeSlice_Callback`. Deploy-time `Dcb_Builder` does
   not catch it, and the cold-start call would swallow it.
2. **Two entities in one plugin cannot both be annotated.** Adding
   `CategoryLinked{@partitionTag categoryId, imageId}` to hybrid `catalog` throws
   "multiple fields annotated with @partitionTag (productId, categoryId)". The category
   slice's partition is valid on its own terms, yet the plugin cannot deploy. Today no
   category event carries a second id, so the examples never hit this.

The annotation reads as "this slice's partition key", but the storage layer treats it as
"this boundary's preferred key".

### F2 — The "first mentioned" default already exists in storage, silently

`derivePartitionKey` looks up the boundary tag in the event's tags and, when it is
absent, falls back to `tags[0]`. With no partition tag at all it also uses `tags[0]`.
A probe of `DcbTag.extractTags` shows that tags come out in **declaration order**:
`{customerId, addressId}` gives `[customerId, addressId]`, and `{addressId, customerId}`
gives `[addressId, customerId]`. By contrast, `extractTaggedFields` sorts them.

So every event lacking the boundary key (every category event in `catalog`, every
customer or notification event in `ordering`) is stored under its first declared tag.
Today that is harmless: every such event carries exactly **one** tag (verified per slice
against the compiled schemas), and a multi-tag event lacking the boundary key is ruled
out by F1 (unannotated → per-slice throw; annotated on another key → boundary throw).
**Any change that relaxes F1 makes this fallback live**, and field order then decides
storage placement with no signal.

The retained-annotation analysis already flags this fallback as the one place where a
wrong derivation mis-partitions instead of failing
([plan, Phase 4b](../../plans/done/dcb-tag-scope-inference.md)).

### F3 — Failure handling differs at each call site, and local cannot observe it

The same misconfiguration **throws** at slice-builder application, is **swallowed to
`None`** at cold start (on the assumption that deploy rejected it), and is **swallowed
to `""`** per command. The local backends ignore the partition tag altogether, so a
mis-partitioning bug is invisible to local tests and the GWT harness. It shows up only on
DynamoDB, as a missed event in a decision read or two first writers taking different
fence items.

### F4 — "Take the first-mentioned id and warn" is not recommended

1. **Field order becomes semantic.** Reordering record fields is a no-op everywhere
   else in ReScript. Under this rule it would move the partition, strand existing events
   outside the decision read, and change which fence item a create guard takes.
2. **"First" is undefined at boundary scope.** The key is chosen across every produced
   variant of every slice. `X{orderId, productId}` and `Y{productId, orderId}` have no
   common first id, so a tie-break rule would be needed on top.
3. **The key is consistency-critical.** It selects both the base-table partition of the
   decision read and the fence item. A wrong choice is a silent invariant violation or a
   double create, not a performance problem (see the plan's Phase 4b analysis).
4. **A warning does not fit here.** The repo requires zero warnings, the output would
   appear in deploy or boot logs rather than the editor, and F3 shows two of the four
   call sites already swallow the failure.

F2 shows what this default looks like in practice: correct today only because nothing
exercises it.

### F5 — "An id shared with consumed events is the partition" is not recommended

Tested against every slice that carries `@partitionTag` in the examples:

| Slice | Produced keys | Keys on foreign arms | `produced − foreign` | "shared id" rule | `@partitionTag` |
|---|---|---|---|---|---|
| hybrid `AddProduct` | productId, categoryId | categoryId (`CategoryAdded`, `CategoryArchived`) | **productId** | categoryId ✗ | productId |
| hybrid `ShipOrder` | orderId, customerId | customerId, productId (`OrderPlaced`) | **orderId** | customerId ✗ | orderId |
| dcb `CancelOrder` | orderId, productId | productId (`OrderPlaced`) | **orderId** | productId ✗ | orderId |
| hybrid `PlaceOrder` | orderId, customerId, productId | productId (five `CatalogProduct*` arms) | orderId, customerId → ambiguous | productId ✗ | orderId |
| `RecordProductDemand` (both) | productId, orderId | none (consumes only its own types) | productId, orderId → ambiguous | orderId ✗ | productId |

Notes on the rows:

- **`AddProduct`**: partitioning by the shared id puts every product of a category into
  one partition, and runs `ProductAlreadyExists` against the category's history.
- **`ShipOrder`**: this row is the most telling. `orderId` appears on **no** consumed
  arm; the read is scoped by the command. `customerId` is on `OrderPlaced` only to be
  copied onto the shipment.
- **`PlaceOrder`**: `customerId` counts because the shape matches ids by name, and
  `@noDcbTag` on the command does not remove it.
- **`RecordProductDemand`**: a genuine many-to-many join. Both ids belong to the slice,
  and only domain knowledge (demand is counted per product) decides. That is exactly what
  the annotation is for.

**What the proposal gets right.** An id on a consumed arm of the slice's **own** event
type is a self-read, and a self-read is identity evidence: `AddProduct` reads
`ProductAdded({productId})`, and `PlaceOrder` reads `OrderPlaced({orderId})`. As a tie
breaker applied *after* the subtraction, it would resolve `PlaceOrder`. It still picks
the wrong key for `RecordProductDemand` (self-read by `orderId`), and it gives no signal
for `ShipOrder` or `CancelOrder`, whose own arms have no payload. It cannot replace the
subtraction.

### F6 — Foreignness is decided per slice, not per entity

`foreignConsumedKeys` asks whether *this slice* produces the event type. A sibling slice
of the same entity therefore counts as foreign. `ChangeProductName` consumes
`ProductAdded`, which `AddProduct` produces; writing that arm as
`ProductAdded({productId, name})` would subtract `productId` and leave the slice with no
partition, degrading the whole boundary. The convention "a consumed arm must not declare
the id its slice is partitioned by" (the reason
[`ChangeProductName.res`](../../../examples/online-shop-hybrid/catalog/src/Product/StateChange/ChangeProductName.res)
writes `ProductAdded({name})`) and the `partitionBlockers` diagnostic both exist to work
around this.

The original design specified an **owner map built by fixpoint**: seed from slices with
a single produced key, then resolve multi-id producers by eliminating keys already owned
elsewhere. The shipped version dropped the fixpoint ("No fixpoint needed"). A key would
be foreign only if the *producing* slice is partitioned by a different key. That
restores the design and makes "shared within the entity" count as identity, which is the
part of the F5 proposal that holds.

#### Deciding foreignness per chapter instead

A chapter is the optional folder above the kind folder (`src/<Chapter>/<Kind>/…`,
[`Discovery.chapterOf`](../../../reventless/spec/src/generator/Discovery.res#L38)). Today it
is a grouping band on the plugin structure and nothing more. In the examples every DCB
slice sits in one, and most chapters coincide with an entity. The exception is
`Notification`, which holds two entities (`recipientId`, `sourceId`).

Three candidate rules were simulated on the compiled examples (37 slices, 4 plugins).
Each ran twice: on the specs **as written**, and in a **trap** variant where every
consumed arm produced by another slice also names that slice's ids, i.e. the convention
above is not followed. The slice's own event types stay non-foreign in every rule.

| Rule | As written (vs golden) | Trap |
|---|---|---|
| Current: foreign unless *this slice* produces the type | 37/37 | **20 slices lose their partition** |
| A: an arm produced **in the same chapter** is never foreign | 36/37: hybrid `CancelOrder` becomes ambiguous (`productIds` on `OrderPlaced` stops counting as a reference) | 19 of the 20 fixed; `CancelOrder` still ambiguous |
| B: a same-chapter arm protects only the **chapter key**, the intersection of the ids on all the chapter's produced events | 37/37 | all fixed |
| C: an id is foreign unless the **producing slice is partitioned by it**; fixpoint seeded from hints and single-key producers; no chapters | 37/37 | all fixed |

Rule B works, and it degrades safely: a multi-entity chapter has an empty chapter key, so
it behaves like the current rule. Rule C gives the same results without chapters, though,
and B has three costs that C avoids:

- **The chapter key depends on the data.** If every `Order` event also carried
  `customerId`, the key would become `{orderId, customerId}`. A slice that copies
  `customerId` across from `OrderPlaced` would stop subtracting it and turn ambiguous.
  C is unaffected, because `customerId` is not `PlaceOrder`'s partition.
- **Folder layout starts to affect consistency.** Moving a slice between chapters could
  move its partition. The golden would catch that, but it turns a presentation concept
  into a storage input.
- **New input for every call site.** `dcbSliceSchemas`, `Dcb_Builder`, the cold-start
  entry point and `check:dcb-scope` would all need the chapter. Deriving the scope from
  different inputs at different call sites is exactly the drift in
  `dcb-runtime-scope-annotation-drift.md`. C needs only the shapes that every
  whole-boundary call site already has.

Neither rule helps the per-slice GWT harness, which sees one slice and no siblings.

A chapter works better as a **check** than as an input. A slice whose inferred partition
is not its chapter's key (say `categoryId` for a slice under `Product/`) is worth
reporting. The folder is authored intent, like `@partitionTag`, so comparing the two
fits the intent-oracle reasoning without letting the folder decide anything.

### F7 — No compile-time gate

The derivation needs every slice of a boundary together, and the PPX sees one file. The
earliest point that sees a whole plugin is `generate-plugin`, which scans `src/` before
the build. It works from source rather than compiled schemas, so it would need the
source-side shape adapter that `DcbScopeInference`'s schema-agnostic boundary was
designed for (the editor-tooling adapter in the plan). Until then, ambiguity is
detected at the first test, `check:dcb-scope`, boot, or deploy.

### F8 — A `@partitionTag` is never checked against the inference

The hint in rule B overrides the derivation whenever it names *any* produced key
([:199](../../../reventless/spec/src/components/DcbScopeInference.res#L199)), including a
key that the same slice reads from a foreign producer. `@partitionTag categoryId` on
`AddProduct` would be accepted and would drive storage, fence and read scope together.
[`validateScopeVsInference`](../../../reventless/spec/src/components/DcbValidation.res#L461)
already flags the equivalent contradiction for `@crossPartition`; `@partitionTag` has no
such check. The plan keeps the annotation as the **intent oracle** that inference is
verified against, but in this direction the oracle itself is unverified.

---

## Reconciling with the retained `@partitionTag`

The plan deliberately closed "drop `@partitionTag`" as won't-do: the annotation is the
build-time statement of intent on the one decision where a wrong guess is a silent
consistency bug. A tempting follow-on would be "use the inferred partition as the storage
key whenever it resolves uniquely". That reverses the decision, and the evidence here
does not justify it:

- The `dcb-scope.json` golden (added since) freezes `partitionBySlice`, so a *change* in
  inference is caught in CI. But a golden refreshed by `check:dcb-scope:update` records
  the outcome, not the intent. It is a drift guard, not the oracle the plan asks for
  before revisiting.
- F1 and F2 show that making storage follow the per-slice inference is not a local
  change: the storage partition is boundary-wide, and its fallback is positional.

The findings instead point to making the annotation and the inference **check each
other** where today one silently overrides the other.

## Options

Ranked by value against effort. None is scheduled.

1. **Cross-check `@partitionTag` against the inference (F8).** An error when the
   annotated key is foreign to its slice; info when inference resolves the same key
   unaided (redundant but kept, per the plan's decision). Pure spec-level change beside
   `validateScopeVsInference`; no storage impact.
2. **Make the storage fallback loud (F2).** Throw (or at least log an error) from the
   boundary derivation when a produced multi-tag variant lacks the boundary key, instead
   of relying on `tags[0]`. Closes the positional default before anything relaxes F1.
3. **Unify failure handling (F3).** Derive once per boundary and fail in the same way
   everywhere; keep the cold-start catch only as a documented last resort that logs at
   error level.
4. **Entity-level foreignness via the producer-partition fixpoint (F6, rule C).** Removes
   the "don't name your own id on a lifecycle arm" trap and the plugin-wide degradation
   it causes. Simulated: it matches all 37 golden partitions and fixes all 20 trap
   slices, with no new input. Preferred over deciding foreignness per chapter (rule B);
   if chapters are used at all, report a slice whose partition is not its chapter's key.
5. **Per-slice (per-entity) storage partitions (F1).** Lets two entities in one plugin
   both annotate their partitions. This touches `derivePartitionKey`, fence selection
   and the cold-start derivation, and needs a DynamoDB conformance test, because local
   backends cannot observe partitioning (F3).
6. **Earlier gate in `generate-plugin` (F7).** Needs the source-side shape adapter.

**Not recommended:** a first-mentioned default with a warning (F4); treating an id shared
with consumed events as the partition (F5), except as a self-read tie breaker after the
subtraction.

## Open questions

- Is the cold-start `catch → None` still needed once deploy fails loudly on every
  misconfiguration, or does it only hide drift between the deployed schemas and the
  bundled ones?
- Option 5 changes the stored `id` of existing category / customer / notification
  events only if the chosen key differs from today's `tags[0]`. For all current events
  it does not (single tag), but this needs confirming on a real table before any
  migration claim.
- Should the self-read tie breaker (F5) be adopted with option 4, or would it make
  `RecordProductDemand`-style joins resolve to the wrong key without the annotation
  that currently forces a decision?
