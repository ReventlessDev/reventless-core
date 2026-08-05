# Analysis: sequencing the live-update change descriptor

**Context:** groundwork for `docs/plans/live-update-state-payload.md`, which carries the
changed row's state in the live-update descriptor. That plan's work item 4 — "decide the
counter's scope" — turned out to hide a feasibility question rather than a scoping one.
This file records what was found, what it costs, and what was decided.

---

## 1. There are three publish sites, not two

The plan lists two. The wire format actually has three independent implementations:

| # | Site | Language | Trigger | Has in hand |
|---|---|---|---|---|
| 1 | `LocalStateChangeDescriptor.make`, called from `QueryDbStorage_InMemory` / `_Sqlite` | ReScript | inside the QueryDb write | the full new state |
| 2 | `StateTopic_AppSync_Ops.processRecord` | ReScript | DynamoDB stream record | `NewImage` / `OldImage`, stream metadata |
| 3 | `StateTopicPublish.mjs` `withLiveUpdates` | hand-written ESM | inside the Postgres projection write | the full new state |

Site 3 exists because Postgres read models have no change stream, so the projection Lambda
publishes the descriptor itself. It is the same wire contract by construction and is
therefore in scope for every change to that contract — including the parity test.

## 2. What each site can reach

The three sites see very different things, and that asymmetry is the whole story.

- **Sites 1 and 3 are inside the write.** They hold the state being written and any
  process-local state they care to keep. They do *not* see any storage-assigned version.
- **Site 2 is outside the write.** It sees only what DynamoDB puts on the stream record:
  `Keys`, `NewImage`, `OldImage`, `eventID`, `eventName`, and `SequenceNumber`. It has no
  connection to the writer and no memory between records — the same Lambda serves every
  streamed table via `STATE_TOPIC_MAP`.

So the only per-entity value all three can agree on is one that either (a) lives on the row,
or (b) each site derives independently from something monotonic it already has.

## 3. A dense counter is not reachable without changing the write path

Dense — consecutive, gap-detectable — numbering has to be maintained by whoever writes,
and read by site 2 off the row. That means a framework attribute on every read-model row.
There is precedent for such an attribute: `Util_DynamoDb_Runtime.insertTtl` already stamps
`reventlessPurgeTime` onto the item.

The cost is concentrated entirely in the DynamoDB backend.

**3.1 Single saves stop being `PutItem`.** `QueryDbStorage_DynamoDb_Runtime.save` uses
`putWithRetries` — a whole-item replace, which cannot increment anything. Two ways out:

- `UpdateItem` with `ADD #seq :one` plus `SET` of every state attribute. This requires
  synthesising an UpdateExpression from arbitrary projection JSON (nested records, arrays,
  reserved words, `#name` escaping). More importantly, `UpdateItem` *merges* where
  `PutItem` *replaced*: an attribute the projection stopped emitting used to disappear from
  the row and would now persist. That is a silent semantic change to every read model in
  the framework, and it fails as a resurrected stale field rather than an error.
- Read-then-conditional-put on the previous counter value. Preserves replace semantics at
  the cost of one extra read per projection write plus a contention retry loop. Partly free
  for the `Update` / `UpdateWithDefault` arms, which already `loadAtMost(2, id)` before
  saving (`Projection.res`), but not for `Set` or the `Create` / `Init` arms, which write
  blind.

**3.2 Batch saves cannot increment at all.** `saveBatch` goes through `BatchWriteCommand`,
and `BatchWriteItem` supports only `PutRequest` / `DeleteRequest` — there is no update mode.
Batch saves would either drop to N individual `UpdateItem` calls (25 rows becoming 25 round
trips instead of one batched call) or publish descriptors carrying no sequence at all. The
second option makes the wire format conditional on how the projection happened to write,
which is the drift the plan's parity test exists to prevent.

**3.3 Delete and TTL reset the counter invisibly.** A row removed and later re-added starts
at 1 again. A client still holding the pre-delete value rejects every subsequent payload for
that key as stale, permanently, until something forces a refetch. Closing that needs a
tombstone outliving the row, with its own expiry policy; TTL expiry has the same shape and
no delete event to hang a tombstone off.

**3.4 A row-borne counter is visible.** Read paths do not strip framework attributes today —
`reventlessPurgeTime` is written and never removed. Since the state payload the plan adds
*is* the row, the counter would ride along on the wire and into every reader. Either it
becomes a visible field on every read model, or stripping must be added to each read path
plus the new payload builder.

The other three backends are cheap by comparison: a column in the SQLite upsert, a dict in
the in-memory arm, `ON CONFLICT … seq = seq + 1` in Postgres.

## 4. What dense numbering would actually buy

Less than it appears. It lets a client distinguish "I have every change" from "I missed
one" — but only once a *later* change arrives to expose the gap. If a descriptor is dropped
and nothing else ever touches that row, there is no subsequent message, no visible gap, and
the client stays stale exactly as it would without sequencing. Gap detection is retroactive;
it does not detect silence. The dominant real cause of loss — the socket dropping — is
already covered by the Tier-1 reconnect refetch.

Where dense numbering does become load-bearing is field-level deltas, which the plan
deliberately defers. A patch cannot be applied to a base you are unsure of. A full row has
no such dependency: it is self-sufficient, and a monotonic token is enough to reject an
out-of-order one.

## 5. Decision — monotonic, not dense

The descriptor carries `seq`: a decimal string that only ever increases for a given entity,
with no promise of consecutiveness.

| Site | Source |
|---|---|
| DynamoDB relay | the stream record's `SequenceNumber` — monotonic within the entity's shard lineage, already present, nothing written to the table |
| Local (both backends) | a process counter seeded from the wall clock, so it keeps rising across restarts |
| Postgres publisher | the same wall-clock-seeded counter, per projection-Lambda instance |

Consequences accepted, and worth stating plainly:

- **Values are not comparable across sites.** The DynamoDB numbers are ~26-digit stream
  sequence numbers; the local and Postgres ones are epoch-millis-derived. A client compares
  `seq` only against the previous `seq` it saw for the same entity on the same channel.
- **Concurrent Postgres projection instances are ordered by wall clock**, not by a shared
  counter, so two instances writing the same entity within the same millisecond have no
  defined order. This is an ordering hint, not a lock.
- **No gap detection.** A client cannot tell a dropped descriptor from a quiet entity.
  Recovery stays the reconnect refetch, plus the existing "refetch when membership may have
  changed" rule.

The client contract is therefore: *apply `state` when `seq` is greater than the `seq` you
hold for that entity; ignore it otherwise; refetch on reconnect and whenever list
membership may have moved.*

## 6. Payload size

AppSync Events caps a publish at ~240 KB, and the descriptor is embedded as a JSON string
inside the publish body, so escaping inflates it. The state payload is capped at 60 K
**characters** of serialised JSON rather than bytes: counting characters keeps the rule
identical across the three implementations without a UTF-8 length binding, and the limit is
low enough that worst-case UTF-8 (3 bytes per character) plus escaping still fits the
envelope. Over the cap the publisher emits the metadata-only descriptor and logs
`STATE_PAYLOAD_DOWNGRADED` — never a silent drop, and never a failed publish. Clients must
therefore treat `state` as optional on every frame.

The same cap applies on the local path even though nothing there enforces it. Parity is the
reason: a UI that only ever ran against the local platform must not come to depend on
payloads that production would degrade.

## 7. Authorization

`Authorization.permission` is evaluated per component, and no row-level or field-level rule
exists anywhere in the framework, so a subscriber authorized for a read model can already
query every row in it. Carrying a row over that read model's channel discloses nothing new.

The plan flags one condition that would break that reasoning: index-level group gating via
`ReadModel.indexConfig`'s optional `authorization {tableName, group}`. Checked — no read
model in this repository declares it. The only `authTable` references are the AppSync
resolver machinery that would consume it (`QueryDbResolvers_Lambda`,
`PgQueryResolver_Lambda`) and their test. Component-scoped authorization is therefore as
fine-grained as it gets today, and the payload needs no additional gate.

This stops holding the moment a read model does declare index-scoped authorization: at that
point "authorized for the component" is coarser than "authorized for these rows", and the
payload would widen access. That condition belongs on any future work that introduces it,
not as a gate on the current change.

## 8. Deliberately unchanged

- **`Removed` carries no state.** There is no new row. The old image is available on the
  DynamoDB path but not on the others, so including it would be the one asymmetry the
  parity test could not cover.

One pre-existing divergence was closed to make the parity test meaningful: the DynamoDB
relay used to emit `sortKeyValue` on a REMOVE, read off the OldImage, while the local and
Postgres publishers never could. It now omits it, matching the other two. A sort position
for a row that no longer exists has no consumer — `sortKeyValue` is used to classify an
*added* row against a list's current sort range.
- **No shared descriptor module.** Promoting the builder into `reventless-core` would
  remove two of the three implementations, but the DynamoDB relay's `_Ops` module is
  deliberately runtime-pure and Pulumi-free, and a core import risks pulling deploy-time
  code back into a Lambda's import graph — a regression this repo has already paid for
  once. The parity test is the cheaper guard.
