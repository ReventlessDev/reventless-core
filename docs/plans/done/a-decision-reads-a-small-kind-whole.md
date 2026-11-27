# Plan: a decision reads a small kind of event whole

**Status**: Done 2026-11-27. [KQ1](#6-questions-and-answers) and [KQ2](#6-questions-and-answers) were
decided as recommended. The build differs from the proposal in four places, each recorded where it
happened: the reader's clause ([KD1](#3-decisions)), a fence the reader's append dropped on DynamoDB
([KD5](#3-decisions)), a command with no tags ([KD6](#3-decisions)), and the example
([§1](#1-the-case)).<br/>
**Nature**: a new read scope, opted into on the consumed case. It reuses the cross-partition read and
its fences, so the stores gain no new kind of index or fence. No change for apps that do not opt in,
except on DynamoDB, where a reader's cross-partition clause it does not write is now checked
([KD5](#3-decisions)). An app that opts in on a deployed stack tags its stored events once.<br/>
**Touches**: `reventless/spec` (`DcbScopeInference`, `DcbTag`, `DcbValidation`, `StartRefusal`), the
PPX (`ReadWholeInference`), `reventless/core` (`StateChangeSlice_Callback`, `Dcb_Builder`),
`reventless/gwt` (`Decision_GWT`, `Flow_GWT`), `reventless/aws` (the DynamoDB runtime,
`DcbKindBackfill`, the `tag-kinds` bin), the tests of the local and Postgres backends,
`check:dcb-scope`, and the hybrid shop.

Related: [a decision reads its own key across partitions](a-decision-reads-its-own-key-across-partitions.md)
(the pair, whose route and fence this reuses), [dcb-phase7-cross-partition-reads](dcb-phase7-cross-partition-reads.md)
(the per-tag index read), [dcb-fence-event-type-granularity](dcb-fence-event-type-granularity.md)
(fences per tag and event type).

## In plain words

A decision finds the events filed under the tags its command carries. Some decisions need a short
list that no command names by a tag: the fees of a shop's shipping methods, a price list, a set of
settings. Each entry is kept under its own name, so a decision about an order finds none of them.

Before this, the only ways round it were to copy the list onto every record that might need it, or
to make the decision read nothing but the list. A decision can now read **every event of a kind**
beside what it reads by its tags, for the kinds it marks. It is meant for kinds with few events: the
decision reads all of them on every command, and any write of the kind conflicts with it.

## 1. The case

The hybrid shop's ordering keeps shipping fees: `SetShippingFee({shippingMethod, fee})` keeps one
fee per method (*Standard*, *Express*, *Pickup*), stored under the method's name
(`shippingMethodId`), and produces `ShippingFeeSet`. `PlaceOrder`, partitioned by `orderId`, records
the fee of the order's method on `OrderPlaced` (`shippingFee`, beside the total, not in it). Its
command names the method as an enum, which is no DCB tag, so no read by the command's tags finds
the one fee.

`PlaceOrder` lists `ShippingFeeSet` among its consumed events. Its query is one clause by `orderId`,
which no `ShippingFeeSet` carries, so narrowing drops the type and the decision sees no fee.

*Changed from the proposal:* the proposal placed the case in the DCB shop, as delivery fees quoted
for every option. It moved to the hybrid shop, which core CI deploys, so the whole read runs on a
real table; there the order has chosen its method already, so it records that method's fee rather
than a quote of all of them.

## 2. What existed

- A clause with no tags matches every event of its types. A command with no tags built one, and
  every store reads it: the local stores by filtering, DynamoDB by a scan
  ([`DcbEventLogStorage_DynamoDb_Runtime.res`](../../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res)).
  But a command with tags could not add such a clause beside them.
- On DynamoDB that scan is guarded by no fence: the append condition skips a clause with no tags.
  A write of the kind between the read and the append is not seen.
- A cross-partition clause (one tag, its key read across partitions) reads by the per-tag index, and
  every writer of an event carrying the tag bumps its fence per event type, which the reader checks
  with a count. This is what a pair uses.

## 3. Decisions

**KD1. A kind is read whole by a tag every event of it carries.** An event of a kind some slice of
the boundary reads whole is tagged by the kind tag, `{key: "reventless.kind", value: <event type>}`,
when it is appended: inference adds the kind key to the type's indexed keys, and the append path adds
the tag where it finds that key. The reader's clause is `{eventTypes: [type], tags: [kind tag]}`,
and the kind key joins the boundary's cross-partition keys, so the read, the fence, its count and the
writer's bump are the cross-partition read's. *Changed from the proposal:* the clause carries no
`crossPartition: true`. That flag marks a pair's clause, which DynamoDB's append leaves out of the
fence check and checks on the pair's own fence item instead; a whole read has no such item.

**KD2. A whole read is opted into on the consumed case, with `@readWhole`.** `PlaceOrder`'s
`consumedEvent` marks `@readWhole ShippingFeeSet({shippingMethodId, fee})`. The PPX emits
`let consumedEventSchema = Reventless.DcbTag.readWhole(consumedEventSchema, [...])` after the
declaration, naming each case as it is on the wire, so the deploy-time builder and the deployed
command handler read it off the schema alike. A case without the marker is read as before; the
marker on any other type fails the build.

**KD3. A case read whole takes no part in the slice's partition.** Inference leaves it out of the
foreign reads (rule 1), the cross-partition candidates (rule 2), the indexed keys (rule 3) and the
command scope (rule 4) (`DcbScopeInference.partitionArms`), and the validation never calls it stored
elsewhere. Its type leaves every tagged clause of the query.

**KD4. The boundary knows its whole kinds.** `DcbScopeInference.infer` derives `wholeEventTypes`,
and `deriveEffectiveScope` keeps them on the fallback too, since they are read off the schemas. The
builder logs one line per kind, which `check-start` prints beside the pairs, adds the
`tag_reventless.kind` index, and `check:dcb-scope` records the kinds as `wholeEventTypes`.

**KD5. A cross-partition clause the reader's append does not carry is checked.** *Found in the
build.* DynamoDB's conditional append turned each cross-partition clause into a conditional update
of its fence, and dropped one whose tag no appended event carries, as a "misconfigured clause". A
whole read's reader never writes the kind, so its check was dropped and a stale append went through;
the same held for a cross-partition reference read whose key is payload on the reader's own event.
Such a clause is now a read-only condition check, by the count the reader read where the fence is
counted. This brings DynamoDB in line with the local stores, which check the whole query.

**KD6. A command with no tags reads its whole kinds by their kind clauses too.** *Added in the
build.* `SetShippingFee`'s command carries an enum and no tag, so it reads the fees whole. A clause
by type alone would be the unfenced scan of [§2](#2-what-existed); the kind clauses are fenced. Its
other types keep their clause by type.

**KD7. The kind tag stays out of `tag_composite`.** It names the event's type, not its entity, so a
composite read of the entity's tags still finds the event once its kind is read whole.

**KD8. A kind no slice of the boundary writes is refused.** Only a slice's append tags an event by
its kind, so a kind written by an aggregate or another boundary would never be found. The builder
refuses the start with `whole-read-unwritten`.

## 4. Phases

### KR1. The spec: marker, shape, inference, query

The PPX reads `@readWhole` into the schema ([KD2](#3-decisions)). `eventShape` gained `whole?: bool`;
inference and validation follow [KD3](#3-decisions) and give `wholeEventTypes`.
`buildQueryFromCommand` takes `~wholeEventTypes` ([KD1](#3-decisions), [KD6](#3-decisions)).

*Done:* `DcbScopeInferenceTest` covers the boundary (partition `orderId`, the kind read across
partitions and indexed on its writer, a case read whole changes no partition, a kind with no writer
refused); `DcbTagTest` covers the clauses, the kind tag and the schema marker; the PPX suite covers
the emitted shadow, `@as`, and the refusal on a produced event.

### KR2. The append path tags, the local stores read

The core append path adds the kind tag to each event of a whole kind; the slice callback reads the
kinds its schema marks, and logs a warning when one returns more than 100 events
([KQ1](#6-questions-and-answers)). `Decision_GWT` builds the query the same way; `Flow_GWT` treats
the kind tag as carried by every entry of its type.

*Done:* `PlaceOrder`'s GWT case records the latest fee of its method, and the ordering flow sets the
Express fee and finds it on the order. `DcbWholeReadStorageTest` (in memory and SQLite) and the
Postgres integration suite read every event of the kind across partitions and conflict on a write of
it between read and append.

### KR3. DynamoDB: the index, the fence, the backfill

The kind key is one more tag key: it gets its `tag_reventless.kind` index at deploy, and its fences
are bumped and counted as a cross-partition key's. [KD5](#3-decisions) and [KD7](#3-decisions)
landed here. `tag-kinds --table <name> --kinds <Type,...>` (from `reventless-aws`) tags the stored
events of each kind once, moves the kind's fence, and counts it as `count-fences` does.

*Done:* `DcbWholeRead_IntegrationTest` on DynamoDB Local reads every fee across partitions, refuses
an append that did not see a fee set since its read (and fails without [KD5](#3-decisions)), and
tags fees stored before the kind was read whole, once.

### KR4. The example and the guide

The hybrid shop gained the `Shipping` chapter (`SetShippingFee`) and `PlaceOrder`'s `shippingFee`
([§1](#1-the-case)). The DCB guide (`packages/doc/docs-app/dcb-usage.md`) says when a whole read fits
and when it does not, and how to tag a deployed table; the PPX reference lists the marker.

*Done:* the shop's tests, `check:dcb-scope` (with `wholeEventTypes: [ShippingFeeSet]`),
`check:lifecycle` and `check:graphql` pass with their goldens refreshed.

## 5. What it costs

Every command of a reader reads every event of the kind, and every write of the kind moves the
kind's fence, so it conflicts with every reader in flight. For a list of a few entries changed
rarely, both are negligible. For a kind that grows (orders, sessions) it is wrong, and the guide
says so. The first deploy that reads a kind whole adds an index to the table, which DynamoDB builds
while the deploy waits.

## 6. Questions and answers

**KQ1. Should the platform refuse a whole read of a kind that is large?**
**Answer:** no refusal, a warning: the platform cannot know a kind's size before it runs. The read
logs a warning when it returns more than 100 events, so a misuse shows in the logs without breaking
a running app.

**KQ2. Is the kind tag `kind`, or a name no app can use?**
**Answer:** a reserved key, `reventless.kind`: no field name can hold a dot, so the tag never clashes
with an app's own `kind` field, and a DynamoDB index name may hold one (`tag_reventless.kind`).
