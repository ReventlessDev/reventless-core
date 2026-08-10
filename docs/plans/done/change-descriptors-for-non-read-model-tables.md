# Plan: Change descriptors for tables that are not read models

**Status**: Done (2026-08-10)

**Nature**: Additive seam generalization in `reventless-aws`, entirely within
`reventless/aws/src/adapter/StateTopic/`. No behavior change for read models —
the existing entry point is reimplemented as a caller of the generalized one,
so an unchanged stack must preview as zero changes. Extends the publish chain
built in [graphql-subscriptions-appsync.md](../graphql-subscriptions-appsync.md);
orthogonal to [realtime-change-descriptors.md](../realtime-change-descriptors.md),
which reshapes the payload and channel layout for read models and applies to
whatever registers, including anything this plan admits.

## Motivation

**The relay is already generic over tables; only the front door is not.**
`StateTopic_AppSync_Ops` is triggered by DynamoDB streams and routes per record
through `STATE_TOPIC_MAP`, a plain `{ <tableName>: <topicName> }` injected at
deploy time. It derives the entity channel from the record's own `Keys` and
publishes `{changeKind, id, sortKeyValue?, seq, state?}`. Nothing in that path
knows or cares whether the table backs a read model.

The only way in does care. `StateTopic_AppSync.make` takes `~readModelName`,
resolves the stream by looking up QueryDb storage resources for a read-model
spec name, and is called from `subscriptionInfraHook` in `Platform.res`, which
iterates `allQueryDbs` and keeps those present in
`QueryDbStorage_DynamoDbStream.streamRegistry`. A component that provisions its
own DynamoDB table therefore cannot publish change descriptors, even when its
rows are exactly the shape the relay expects.

**Such tables exist, and making them read models would be a category error.**
A read model is a projection of the event log: derived, and rebuildable by
replay — which is why losing one is an inconvenience rather than a loss. Some
framework-adjacent state is neither. A platform-scoped ledger written by
runtime collectors across several plugin stacks, accumulating through atomic
`ADD` increments, measuring activity that leaves no event behind (a request
that is refused writes no event; a read writes nothing at all) is a *primary*
record. It is protected against destroy precisely because there is no backfill
for it. Declaring it a read model would assert it can be rebuilt from events,
which is the one thing it cannot do.

**The alternative available today is strictly worse.** A host that wants such
data to stay fresh has to poll. Polling costs the same whether or not anything
changed, while a stream is silent when idle — so for the common case of a quiet
platform, the mechanism we currently force on callers is the more expensive
one, and it is also the one that cannot say *when* something changed.

## Items

### S1 — a table-shaped registration entry point

Add alongside the existing `make`:

```rescript
let makeForTable = (
  ~tableName: Pulumi.Output.t<string>,
  ~streamArn: Pulumi.Output.t<string>,
  ~topicName: string,
  ~eventsApi: AppSync_EventsApi.t,
  ~opts: Pulumi.CustomResourceOptions.t,
) => ...
```

appending the same `{tableName, streamArn, topicName}` entry the read-model
path already builds. Then reimplement the current entry point in terms of it:
`make(~readModelName, …)` resolves the stream and table name through the QueryDb
lookup exactly as now, and calls `makeForTable`.

One registry, one `finish`, one shared Lambda, one IAM statement, one
`STATE_TOPIC_MAP` — every consumer of the registry is untouched, which is what
makes this cheap and what makes "unchanged stack previews as zero changes" a
meaningful gate rather than a hope.

**Done.** `StateTopic_AppSync.makeForTable` in
[StateTopic_AppSync.res](../../../reventless/aws/src/adapter/StateTopic/StateTopic_AppSync.res)
carries one extra parameter beyond the sketch — `~partitionKeyName` — because S3's
check has to observe something (see below). `make` resolves the QueryDb stream
exactly as before and delegates. `finish` and the registry type are unchanged.

### S2 — topic naming becomes the caller's responsibility, and must say so

For a read model the topic is derived from the generated plural list field, so
publisher and subscriber agree by construction. A self-provisioned table has no
generated field to derive from, so `~topicName` is supplied by the caller.

This is a footgun worth naming in the doc comment: nothing validates that the
supplied topic matches what any client subscribes to, and a mismatch fails
*silently* — descriptors are published successfully to a channel nobody is
listening on. The rule to document is that the topic belongs to whoever reads
the data, and that the reader and the registration must be changed together.

**Done.** Point 1 of the "Tables that are not read models" section in the module
header, alongside a worked `makeForTable` call.

### S3 — the key convention must be checked, not assumed

`StateTopic_AppSync_Ops` builds the entity key from the record's `Keys` on the
framework convention that the partition attribute is `id`, with at most one
sort-key attribute. Core guarantees that for QueryDb tables. A table the
framework did not create can be keyed anything, and a violation does not fail —
it publishes descriptors carrying a wrong or empty id, which surfaces later as
clients refetching the wrong entity.

Preferred fix: validate at deploy time and fail the build with a message naming
the offending table and its actual key schema. Cheap, and it converts a silent
runtime mystery into a build error. If a caller with a genuinely different key
layout appears, the escape hatch is an optional `~entityKeyOf` mapping supplied
at registration — but do not add it before there is a caller, since an
unexercised mapping seam is another way for publisher and reader to disagree.

**Done, with the preferred fix and no escape hatch.**
`StateTopic_AppSync_Helpers.checkPartitionKeyName` throws with the table name and
its actual key. Two decisions worth recording:

- **Only the partition attribute is checked.** The "at most one sort key" half of
  the convention needs no check: a DynamoDB table cannot have more than one, so
  the relay's `{id}-{sortValue}` composition is total by construction.
- **The check rides on the registered `tableName`**, not on an apply of its own —
  `STATE_TOPIC_MAP` is built from that Output, so the apply always runs and cannot
  rot into dead code. The cost of naming the table in the message is that on the
  *first* deploy of a new table, where the physical name is still unknown at
  preview, the failure lands during the update instead of the preview. It fails
  the deploy either way.

No `~entityKeyOf` was added — there is still no caller with a different key
layout, which is the condition the plan set.

The read-model path supplies the framework-guaranteed `"id"`, so the check
restates an invariant there rather than observing one; it exists for tables the
framework did not create.

### S4 — confirm IAM needs no change

`finish` grants the relay Lambda stream-read permissions from the registered
entries' ARNs (`resources: Resources(streamArns)`), so a table entry is covered
by construction. Verify this rather than assume it, and record the result here —
a missing grant would present as an ESM that exists and never delivers, which
reads like a broken stream rather than a policy gap.

**Confirmed — no change needed.** `finish` builds the policy's
`AllowReadDynamoDbStream` resource list as `entries->Array.map(e => e.streamArn)
->Pulumi.Output.all`, i.e. from *every* registry entry regardless of origin. A
`makeForTable` entry contributes its `streamArn` through the identical field, so
it is granted by the same statement that already covers read models. The same is
true of `AllowPublishAppSyncEvents`, which is scoped to the events API rather than
to any table.

### S5 — registration stays explicit, and the cost is stated

Never register a table automatically because it happens to have a stream. A
stream on a write-hot table means a relay invocation per batch of row changes,
and the whole reason some of these tables exist is to avoid per-write and
per-read work. Registration is per table, opt-in, at the site that owns the
table — and the doc should state the trade-off plainly: free when idle, not
free under a write burst, so measure before enabling it on a hot table.

**Done.** Point 3 of the module header states the trade-off in those terms.
Nothing auto-registers: `subscriptionInfraHook` in `Platform.res` still iterates
`allQueryDbs` filtered by `QueryDbStorage_DynamoDbStream.streamRegistry`, and
`makeForTable` has no caller inside the framework — it is a seam for the
component that owns the table.

## Verification

- **No-op for read models** — holds, by inspection of the emitted JS rather than
  a live preview (no deployed stack was available in this session). The generated
  diff in `StateTopic_AppSync.res.mjs` shows `make` producing exactly the former
  registry entry, with `tableName` now passing through one additional
  `Pulumi.all([tableName, output("id")]).apply(…)` that returns the same string.
  Every resource input downstream — `STATE_TOPIC_MAP`, the ESM name
  (`topicName ++ "Stream2" ++ …`), the policy's stream ARNs, the Lambda's code
  hash — is computed from unchanged values, so an unchanged stack has nothing to
  diff. **Re-run a real `pulumi preview` before the first deploy that carries
  this** — the reasoning is sound but the gate the plan asked for is empirical.
- **`makeForTable` → one `STATE_TOPIC_MAP` entry, one EventSourceMapping** — holds
  by construction: one registry entry produces one `dict->Dict.set(tableName,
  topicName)` and one iteration of `finish`'s `entries->Array.forEach` ESM loop,
  the same loop read models already go through. Not covered by a test — the
  registry functions take an `AppSync_EventsApi.t`, which cannot be fabricated
  headlessly without `Obj.magic`.
- **Key-schema violation fails the deploy, with the table named** — covered by
  [StateTopicKeySchemaTest.res](../../../reventless/aws/tests/StateTopicKeySchemaTest.res)
  (convention accepted; violation rejected; message names both the table and its
  actual key). Green.
- **Descriptors arrive on the supplied topic with a matching entity key** — not
  verified; needs a registered table on a live stack. The publish path itself is
  the one read models already use, unchanged by this plan, and is covered by
  `StateChangeDescriptorParityTest`.

Build: root `pnpm run build` clean, zero warnings. Tests: `reventless-aws`
50 suites / 501 tests green.

## Related defect, found while investigating — fixed separately

Split out, since it was not this seam's problem:
[stateviewslicestream-switch-deletes-projection-esm.md](stateviewslicestream-switch-deletes-projection-esm.md).
Root cause: `connectLambda` created its role policy and every EventSourceMapping
inside one apply shared with the slices' view tables, whose computed `streamArn`
is unknown in the preview that enables it — so an unknown in one input deleted
resources that never read it. Fixed and regression-tested.
