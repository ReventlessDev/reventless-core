# Plan: Derive event source from the channel, not a persisted per-row `meta.service`

## Problem

`meta.service` plays **two unrelated roles** that happen to share a field:

1. **Routing / source identity** — dispatch selects handlers by service name. Every
   service-based routing site reads it off the decoded event via `Message.serviceNameOfMsg`:
   the EventCollector demux
   ([`Plugin_Callback`](../../../reventless/core/src/plugin/component/Plugin_Callback.res#L54)
   `:54,70`), and the outgoing-mapping lookups in
   [`Extension_Operations`](../../../reventless/core/src/components/Extension/Extension_Operations.res#L50)
   `:50` and
   [`ExtensionPoint_Operations`](../../../reventless/core/src/components/ExtensionPoint/ExtensionPoint_Operations.res#L28)
   `:28`.
2. **A value stamped on every stored row.** At DCB append,
   [`DcbEventLog_Operations.append`](../../../reventless/core/src/components/DcbEventLog/DcbEventLog_Operations.res#L117-L133)
   normalises `meta.service` to the log's own identity (`"<plugin>DcbEventLog"`) and it is
   flattened into every persisted item.

The routing role is real and (partly) unavoidable — see Non-goals. The **per-row storage**
of it is, on inspection, **redundant with the channel identity**, and only load-bearing
because one dispatch path chooses to re-read it from storage instead of deriving it from the
trigger:

- A DynamoDB-stream event-source mapping is bound to **exactly one** source table (1:1). The
  logical source is therefore knowable from the ESM / channel config alone.
- But the stream collector runtime
  ([`EventCollectorChannel_DynamoDbStream_Runtime`](../../../reventless/aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res#L13-L25))
  uses `record.eventSource` **only to choose the record decoder** (`aws:sqs` body vs
  `aws:dynamodb` `NEW_IMAGE` vs the Postgres relay body), then hands the decoded event to the
  same payload-`service` demux. It holds the trigger identity and discards it for routing —
  so the stored `service` on the row is what actually routes.

Net: `meta.service` is a **routing tag**, not producer provenance, and the framework
persists it per event even though the source is intrinsic to the channel delivering it.

## Goals

- Stop **depending on** a persisted per-row `service` for dispatch. Derive the logical source
  from the channel/ESM at the boundary (a stream/relay bound 1:1 to a source knows its
  source name from config), and stamp it onto each decoded record before it reaches the
  service-based dispatch.
- Once no reader depends on the stored value, stop **writing** it into rows — freeing the
  row's identity meta to carry only true provenance (the producing component; see
  [event-meta-emitting-component-attribution.md](event-meta-emitting-component-attribution.md)).
- No behavioural change to routing: the same events reach the same handlers; only the
  *source* of the source-name changes (channel config instead of stored payload).

## Non-goals

- **Removing the source key from the published wire envelope.** Under the cross-plugin
  fan-in topology, many EventTopics fan into **one** SQS queue
  ([`EventCollectorChannel_Helpers`](../../../reventless/aws/src/adapter/EventCollector/EventCollectorChannel_Helpers.res#L63-L78)
  `:63-78`; the queue policy at `:20-38` admits any convention-named EventTopic). Past that
  boundary the transport source collapses to `"aws:sqs"`, so a **per-message** source tag is
  required on the wire. That tag is injected at publish time from publisher config —
  `DcbEventLog_Operations.res:81` passes `Ops.serviceName` — **not** read from storage. This
  plan does not touch the wire tag; it only removes the *stored* one.
- **Re-coupling dispatch to per-transport envelopes broadly.** Keep the single
  transport-neutral dispatch keyed on a logical source name; this plan changes *where that
  name is obtained for stream-delivered records*, not the neutral dispatch contract.
- **The producing-component provenance field** — that is the sibling item above; this plan
  is what lets the stored identity meta become provenance-only, but does not itself add it.

## Approach

For every channel that is **1:1 bound to a single source** (DynamoDB-stream ESMs; the
Postgres change-feed relay), the adapter already knows the source name at deploy time
(`~sourceName`, e.g. `EventCollectorChannel_Helpers.res:266`). Thread that name through to
the runtime so the channel **injects** it onto each decoded record, and have the shared
dispatch prefer the channel-injected source over any payload field.

Fan-in channels (SQS fed by SNS) keep reading the per-message source from the wire envelope
as today — the publisher put it there from config. So both channel classes end up with a
logical source per record; neither needs it from a stored row.

## Steps

### Step 1 — Audit every reader of a stored `service`
Confirm the complete set that reads `service` off a **stored** (vs freshly-published) event:
- The stream collector dispatch (`EventCollectorChannel_DynamoDbStream_Runtime` → the
  `serviceNameOfMsg` sites in `Plugin_Callback` / `Extension_Operations` /
  `ExtensionPoint_Operations`).
- Any **EventTopic republish-from-stream** path (a stream-bound Lambda that re-emits stored
  rows to SNS) — verify whether it copies `meta.service` from `NEW_IMAGE` or stamps from
  config; if the former, it is a stored-service reader and must move to config injection.
- Any **replay / reprocess** path that re-reads the log and re-dispatches — confirm how it
  currently obtains the source, and make it inject from the log identity being replayed.

### Step 2 — Thread `sourceName` into the 1:1 channel runtimes
Pass the deploy-time `sourceName` into the DynamoDB-stream (and Postgres-relay) channel
runtime config, and inject it onto each decoded record at the boundary (before the record
reaches `handleEvents`). The fan-in (SQS) runtime is unchanged.

### Step 3 — Dispatch prefers channel-injected source
Update the dispatch entry so the logical source is taken from the channel-injected value
when present, falling back to the payload during migration. Keeps a single dispatch path.

### Step 4 — Stop writing `service` into stored rows (migration-gated)
Once no reader depends on the stored value, drop `service` from the persisted item (or stop
normalising/writing it at `DcbEventLog_Operations.append`). Old rows still carry it; readers
must already ignore it (Step 3). Sequence carefully: **flip all readers first, stop writing
last.**

### Step 5 — Tests
- Stream-delivered event with **no** `service` on the row routes correctly via the
  channel-injected source.
- Fan-in (SQS) event still routes via the wire envelope's source (unchanged).
- Replay of a log re-dispatches with source injected from the log identity, not the row.
- Mixed-backend deployment (SQS + DynamoDB records in one invocation) injects per channel.

### Step 6 — Docs
Update the messages/meta reference to describe `service` as a **wire/routing** identity
supplied by the channel, explicitly **not** persisted provenance, and point to the
producing-component field for provenance.

## Open questions

- **Is the payload wire tag also derivable from the channel on the fan-in path?** Only if
  fan-in is abandoned for 1-stream-per-source everywhere — out of scope, and it would trade
  transport-neutrality for per-adapter envelope mapping. Keep the wire tag.
- **Migration ordering across services.** During rollout, some readers still expect stored
  `service`. Keep writing it until every reader is on channel-injected source; gate Step 4
  behind that. A deployment with mixed old/new components must tolerate both.
- **Postgres relay.** `PgChangeFeedRelay` builds `{id, meta, event}` bodies from a
  source-bound relay — confirm it can inject `sourceName` from its own config the same way,
  so the Postgres path does not silently keep depending on a stored value.
- **Is the simplification worth the migration cost on its own?** It is contained and removes
  a redundant per-row field, but its main payoff is compositional — it lets the stored
  identity meta carry only provenance. Consider scheduling it alongside the
  producing-component field rather than in isolation.

## Status

Not started.
