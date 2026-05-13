# Event Format & Metadata Review — Should Reventless Adopt CloudEvents?

> Date: 2026-05-10 (originally) · Updated: 2026-05-13 (Phase 1 shipped — see "Current State" below for the post-change shape; the analysis of CloudEvents in §4–6 still stands as Phase 2 commentary).
> Companion to: [event-field-naming-comparison.md](./event-field-naming-comparison.md)
>
> Where the companion doc focuses on **field naming consistency** vs. other event-sourcing
> products, this doc takes a **format-design** view: envelope shape, layering,
> portability, and the question of adopting an external standard (CloudEvents).
>
> **Status:** Phase 1 (the "Standardise the Envelope Without CloudEvents" path in §5) is
> implemented — see [`docs/plans/event-envelope-standardization.md`](../plans/event-envelope-standardization.md).
> Phase 2 (CloudEvents wire format) remains on the shelf as a conditional bet.

## 1. Current State

### 1.1 The `Message.meta` envelope

Defined in `reventless/reventless-spec/src/types/Message.res`:

```rescript
@schema
type meta = {
  service: service,         // producer service name
  time: string,             // ISO-8601 producer timestamp
  ip?: string,              // producer IP — absent when unknown
  user?: string,            // acting user — absent for system-initiated messages
  msgId: string,            // UUID, this message
  correlationId: string,    // root id of the correlation chain (defaults to msgId)
  causationId?: string,     // id of the *direct* parent that caused this message
  traceparent?: string,     // W3C Trace Context header, opaque pass-through
  schemaVersion?: string,   // schema version of this message's payload variant
  headers?: dict<string>,   // extensible bag (tenantId, feature flags, etc.)
}
```

`service`, `time`, `msgId`, `correlationId` are required; the rest are optional record fields (`field?: T`) — sury serialises absent fields as missing JSON keys (no `""` / `"unknown"` sentinels). `correlationId` defaults to `msgId` for a chain root.

**Construction:**
- `Message.generateMeta(~service, ~ip=?, ~user=?, ~causationId=?, ~traceparent=?, ~correlationId=?, ~schemaVersion=?, ~headers=?)` — root meta.
- `Message.deriveMeta(~parent, ~service=?)` — child meta: fresh `msgId` + `time`, `causationId = parent.msgId`, inherits everything else. Used by `Aggregate_Callback`, `StateChangeSlice_Callback`, `EventMapper_Callback`, and `Extension_Operations.forwardCommand`.

### 1.2 The on-disk EventLog record (aggregate-style)

`EventLog_Operations.encodeEvent'` builds a typed `StoredEvent` and serialises through `Message.storedEventToFlatJson` (meta keys hoisted to top level for DynamoDB GSI projectability):

```jsonc
{
  "id":  "<aggregateId>",          // partition key
  "position": "000000042",         // sort key — zero-padded sequence string
  "event": "ItemCreated",          // variant tag
  "data":  { /* variant fields, sury-encoded, no TAG */ },
  "recordedAt": "2026-05-13T10:00:00.000Z",  // storage time (set at append)

  // flattened meta — required keys always present, optional keys when set:
  "service": "...",
  "time":    "...",
  "msgId":   "...",
  "correlationId": "...",
  "causationId":   "...",          // present when emitted from a parent message
  // "ip", "user", "traceparent", "schemaVersion", "headers" — present only when set
}
```

The DynamoDB table's range key was renamed from `seq` to `position` to unify with the DCB log; the OCC condition is `attribute_not_exists(position)`.

### 1.3 The on-disk DcbEventLog record (DCB-style)

`DcbEventLogStorage_DynamoDb_Runtime.toItem` writes the same shape, plus DCB-specific extras:

```jsonc
{
  "id":       "tagKey:tagValue",   // partition key derived from tags
  "position": "<unixMs>-<uuid>",   // global sort key
  "event":    "CategoryAdded",
  "data":     { /* variant fields */ },
  "recordedAt": "2026-05-13T10:00:00.000Z",  // NEW — storage time (set at append)
  "tags":     [ {"key": "...", "value": "..."}, ... ],

  // flattened meta — same shape as EventLog (NEW: was previously absent):
  "service": "...",
  "time":    "...",
  "msgId":   "...",
  "correlationId": "...",
  // optional meta keys when set: causationId / ip / user / traceparent / schemaVersion / headers

  // DynamoDB-only GSI helpers, derived from `tags`:
  "tag_<key>":      "value",
  "tag_composite":  "k1:v1#k2:v2#..."
}
```

The DCB log now **persists meta at append time**. `DcbEventLog_Operations.publishToEventTopic` no longer regenerates meta — it uses each event's stored `meta` and overrides only `service` to `<name>DcbEventLog` for EventCollector routing.

### 1.4 The `StoredEvent` type (single source of truth)

Both records above are flattenings of a single logical type — `Reventless.StoredEvent.storedEvent<'id>`:

```rescript
type storedEvent<'id> = {
  id: 'id,
  position: string,
  event: string,           // variant tag (storage column unchanged)
  data: JSON.t,            // sury-encoded payload, TAG stripped
  meta: Message.meta,
  recordedAt: string,
  tags?: array<DcbTag.tag>,
}
```

`Message.storedEventToFlatJson` / `flatJsonToStoredEvent` are the bridges to the on-disk dict shape (meta flattened to top-level). DynamoDB-only `tag_<key>` / `tag_composite` are synthesised by the DCB adapter from `tags` — they are *not* fields on `StoredEvent`.

### 1.5 In-flight Pub/Sub envelopes

When messages cross transport boundaries (SQS, SNS, in-memory bus), they are
wrapped as either:

- `event'<'id, 'event>` = `{ id, meta, event }`
- `command'<'id, 'command>` = `{ id, meta, command }`
- `commandJson` = `{ id, meta, commandJson, delay? }` (post-encode form)

So the in-flight envelope has **three top-level keys** (id, meta, payload-discriminant),
while the stored EventLog record has **eight top-level keys** (after meta-flattening)
and the DcbEventLog record has **four-plus-N** depending on tag count.

## 2. Strengths Worth Preserving

1. **Producer-friendly typing.** The generic `event'<'id, 'event>` and `command'<'id, 'command>`
   are the right shape for sury — the schema can compose `idSchema`, `metaSchema`,
   and a per-aggregate `eventSchema` cleanly.
2. **Sury-driven splitting.** `Message.splitMessage` separates the variant `TAG` from
   the payload before storage. This makes the on-disk schema human-readable
   (`event: "ItemCreated"`) and avoids the awkward `{ TAG: "...", ...payload }`
   shape leaking into DynamoDB scans, AppSync subscriptions, and S3 exports.
3. **Flat meta in storage.** Flattening lets DynamoDB index/project individual
   meta fields without parsing JSON — useful for `correlationId` searches and
   per-user audit GSIs.
4. **Stable, opinionated correlation default.** `correlationId = msgId` if not
   propagated guarantees the field is never empty, which simplifies downstream
   joins.

## 3. Issues With the Current Format

The companion doc enumerates field-naming issues. This section adds
**format-design issues** — things that would not be fixed by a rename alone.

### 3.1 The envelope is implicit and untyped at the storage boundary

There is no type that says "a stored event has these top-level keys." The
shape only exists as an inline `Dict` build in `EventLog_Operations.encodeEvent'`.
Decoding hand-cherry-picks the same keys (`Dict.get("event")`, `Dict.get("data")`).
A schema drift between encode and decode would only surface at runtime.

> **Improvement:** introduce a `StoredEvent` schema (sury) that is the single
> source of truth for the on-disk envelope, used by both encode and decode.

### 3.2 EventLog and DcbEventLog use **different envelope conventions**

| Concept              | EventLog          | DcbEventLog       |
|----------------------|-------------------|-------------------|
| Aggregate / stream id| `id`              | (synthesised from tags) |
| Position             | `seq` (string)    | `position` (string) |
| Event-type discriminator | `event`       | `event`           |
| Payload              | `data`            | `data`            |
| Meta                 | flattened         | absent            |
| Tags                 | n/a               | `tags` + `tag_*`  |

Even where both stores carry the same concept they sometimes carry it
**differently** (`seq` vs `position`, meta present vs absent). A consumer that
ingests both streams must know which side it came from to interpret the envelope.

> **Improvement:** define a **single** "stored event envelope" type that both
> backends serialise into. Backend-specific extras (sequence vs position, tags)
> can sit in a `storage: { ... }` sub-object or as recognised optional fields.

### 3.3 Missing fields

| Field | Why missing matters |
|-------|---------------------|
| `causationId` | Cannot reconstruct the message-graph parent (only the chain root via `correlationId`). Documented in [event-field-naming-comparison.md §10](./event-field-naming-comparison.md). |
| `traceId` / `spanId` | No native OpenTelemetry hand-off. Distributed traces from API → command → event break at the EventLog. |
| `schemaVersion` | sury silently round-trips, but renaming/refactoring an event variant without explicit versioning is a foot-gun. There is no field today that tells a replay "this event was stored with v1 of CategoryAdded." |
| `dataContentType` / `dataSchema` | All payloads are assumed JSON; format and schema URI are implicit. |
| `tenantId` | No first-class multi-tenant key — must hide in `service` or piggy-back on the aggregate id. |
| `producedBy` (component instance / commit sha) | `service` is a logical name; there is no field for "which build of which lambda emitted this." Useful for incident bisection. |
| `dataRedactionLevel` / `pii` flags | No way to mark events as containing PII for data-retention pipelines. |

### 3.4 Misleading or implicit names

(See companion doc for the full table; the worst offenders from a *format* angle:)

- `service` — sounds like a CloudEvents `source` URI, but is actually a free-form
  string. Two services named "ordering" in different environments collide.
- `ip` — required, defaults to `""` in serverless contexts where it is meaningless.
  An always-empty string in storage is wasted bytes and misleading data.
- `user` — defaults to the literal `"unknown"`. Not distinguishable from a real
  user named "unknown". Should be `option<string>` or use a sentinel that cannot
  collide (e.g. URI form `system:internal`).
- `correlationId` defaulting to `msgId` — overloaded semantics. A consumer
  cannot tell "this is the chain root" from "the producer forgot to propagate
  correlation."
- `event` (storage column) and `event` (record field on `event'<>`) — the same
  word is used for both the variant **discriminator string** and the
  **typed variant value**. Confusing in code review and in generated docs.

### 3.5 The `time` field has no precision contract

`time: string` is "ISO-8601" by convention. Some adapters use millisecond
precision (`Date.toISOString`), others would happily produce second precision.
`time` is also **not** the storage time — it's the producer time, and the lag
to storage is invisible. Most other event stores carry both:
`recorded_at` (storage) and `created_at` (producer).

### 3.6 No envelope-level `id` discipline

The top-level `id` field on the stored record is the **aggregate id**, not the
**event id**. The event id (`msgId`) is buried in the flattened meta. This is
the inverse of every other event store and makes "find event by id" queries
require a GSI on a meta field.

## 4. Should Reventless Adopt CloudEvents?

[CloudEvents 1.0](https://cloudevents.io) is a CNCF-graduated specification for
describing event data in a common way. Used by Knative, Azure Event Grid,
Google Eventarc, Argo Events, EventSourcingDB, and (in HTTP-binding form) by
AWS EventBridge schemas.

### 4.1 The CloudEvents core attributes

Required:

| Attribute        | Type   | Reventless equivalent          |
|------------------|--------|--------------------------------|
| `specversion`    | string | (none — implicit)              |
| `id`             | string | `meta.msgId`                   |
| `source`         | URI-ref| `meta.service` (free string)   |
| `type`           | string | `event` (variant tag)          |

Optional context:

| Attribute        | Type   | Reventless equivalent          |
|------------------|--------|--------------------------------|
| `subject`        | string | `id` (aggregate id) — natural fit |
| `time`           | RFC3339| `meta.time`                    |
| `datacontenttype`| string | (implicit `application/json`)  |
| `dataschema`     | URI-ref| (none)                         |
| `data`           | any    | `data`                         |

Plus arbitrary extension attributes (lowercase, alphanumeric), e.g.:
- `traceparent` / `tracestate` (W3C Trace Context — standard extension)
- `partitionkey` (Kafka binding extension)
- `sequence` / `sequencetype` (CloudEvents Sequence extension — exactly fits `seq`/`position`)

### 4.2 What a Reventless event would look like in CloudEvents form

```jsonc
{
  "specversion": "1.0",
  "id":          "01HV...UUID",                 // was meta.msgId
  "source":      "/services/catalog",           // was meta.service, now URI
  "type":        "io.reventless.catalog.ItemCreated",
  "subject":     "item-42",                     // was top-level id
  "time":        "2026-05-10T12:00:00.000Z",
  "datacontenttype": "application/json",
  "data": {
    "itemId":   "item-42",
    "name":     "Widget",
    "priceCts": 1999
  },

  // Reventless-specific extensions:
  "correlationid": "01HV...root",
  "causationid":   "01HV...parent",
  "user":          "alice",
  "sequence":      "42",
  "sequencetype":  "Integer",
  "traceparent":   "00-..."                     // OpenTelemetry hand-off
}
```

(Extension attribute names are required to be lowercase alphanumeric, hence
`correlationid` not `correlationId`.)

### 4.3 Advantages of adopting CloudEvents

1. **Polyglot consumers without a Reventless SDK.** Any tool that already
   speaks CloudEvents (Knative, EventBridge schema registry, Argo Events,
   Dapr, Apache Camel, OpenTelemetry collectors) can ingest events with no
   custom decoder.
2. **AWS-native fit.** EventBridge supports CloudEvents-style schemas in its
   schema registry; SNS/SQS message attributes map cleanly onto the
   "binary content mode" of CloudEvents. Reventless's existing SNS+SQS fanout
   could publish CE-binary with no envelope flattening.
3. **W3C Trace Context for free.** The `traceparent` / `tracestate` extension
   attributes are standard. Adopting them closes the distributed-tracing gap
   identified in §3.3.
4. **Schema registry interoperability.** Tools like Confluent Schema Registry,
   AWS EventBridge Schema Registry, and Apicurio all consume CloudEvents
   schemas as a first-class input. This is the standard wire format for
   "register your event types" workflows.
5. **`source` + `type` URI naming pushes namespace hygiene.** Reverse-DNS
   `type` (e.g. `io.reventless.catalog.ItemCreated`) prevents the
   "two services named 'ordering'" collision; URI `source` makes service
   identity explicit and globally unique.
6. **Sequence extension fits exactly.** `sequence` + `sequencetype` is designed
   for Kafka offsets and event-store positions. Both EventLog (`seq`) and
   DcbEventLog (`position`) collapse onto the same standard field.
7. **Validates the §3.2 unification work.** Adopting CloudEvents *forces* a
   single envelope across EventLog and DcbEventLog — the unification falls
   out of the spec.
8. **Marketing / ecosystem.** "Reventless emits standard CloudEvents" is a
   stronger pitch to platform teams than "Reventless emits a custom JSON shape."
   It also lowers the barrier for evaluators familiar with Knative or Dapr.
9. **Free `dataschema` slot for sury / version migrations.** A `dataschema`
   URI per event variant gives a natural place to anchor event-versioning
   docs and codegen.
10. **Reduces what we must invent.** Causation, correlation, content-type,
    schema-uri, sequence, partition-key — all already specified, with
    multiple language SDKs (Go, Java, .NET, Python, Rust, JS).

### 4.4 Consequences (the costs)

1. **Storage migration.** Today's DynamoDB items use `id` for stream id and
   flatten meta. CloudEvents uses `subject` for stream id and reserves `id`
   for the message id. A migration is breaking for **every existing table**
   and every consumer that reads from DynamoDB streams directly. (Mitigation:
   dual-write window or schema-translating runtime adapter.)
2. **Lowercase-only extension names.** `correlationId` → `correlationid` is
   ugly in TypeScript / ReScript code that expects camelCase. Either accept
   the lowercase (and have ReScript bindings expose camelCase aliases) or
   keep an internal camelCase representation and convert at the wire boundary.
3. **`source` becomes a URI** — every existing service name string would have
   to be normalised to a URI-reference. Not hard, but every downstream
   consumer that string-compares `meta.service == "ordering"` breaks.
4. **`type` becomes reverse-DNS** — current short names like `ItemCreated`
   would change to `io.reventless.catalog.ItemCreated`. The PPX would need to
   prefix automatically (probably from `plugin.json`).
5. **PPX work.** Today the PPX auto-handles `meta`, `id`, schemas. A
   CloudEvents adoption would change what the PPX emits — bigger blast
   radius than a rename.
6. **Loss of "always six required fields" guarantee.** CloudEvents marks
   `time`, `subject`, `datacontenttype`, `dataschema` as **optional**. Today
   we guarantee `time` and `correlationId` are always present. We can keep
   internal invariants stricter than the spec, but consumers reading
   "raw" CloudEvents must tolerate missing optional fields.
7. **`data` is opaque per spec.** CloudEvents officially does not constrain
   `data` shape. Our convention (`{ TAG, ...payload }` or `data: { ... }` +
   `event: "TAG"`) becomes a Reventless-specific layering on top.
8. **Two write modes (binary / structured).** CloudEvents specifies both;
   transports like SNS/SQS naturally favour binary mode (attributes), HTTP
   prefers structured. Our adapters would need to pick — and document — a
   mode per transport. More surface area to test.
9. **Larger payloads on average.** `specversion`, full URI `source`, full
   reverse-DNS `type` together add ~80–150 bytes per event vs the current
   compact form. At DynamoDB scale this is real money.
10. **Cargo-cult risk.** Adopting CloudEvents because it is "the standard"
    without using its ecosystem (EventBridge schema registry, Knative,
    OpenTelemetry collectors) gives us all of the costs and none of the
    benefits.

### 4.5 Opportunities unlocked

1. **AWS EventBridge as a transport.** Today Reventless uses SNS+SQS.
   EventBridge speaks CloudEvents natively (via the `detail` mapping pattern)
   and brings cross-account routing, schema registry, and replay for free.
2. **Knative / Dapr deployment targets.** A Reventless plugin packaged as a
   Knative service or Dapr component becomes a drop-in event producer in
   any CNCF-friendly platform.
3. **EventSourcingDB as a backend.** [`docs/analysis/done/dcb-event-type-coupling.md`](./done/dcb-event-type-coupling.md)
   already notes EventSourcingDB uses CloudEvents natively. A future
   `reventless-eventsourcingdb` adapter would be near-trivial.
4. **OpenTelemetry first-class.** `traceparent` is a CE standard extension.
   Adopting CE makes OTel adoption a tickbox rather than a separate plan.
5. **Schema-driven UI / docs.** A schema registry full of CE schemas can
   power auto-generated event catalogs in the docs site, type-ahead in the
   Workshop UI, and cross-service contract testing.
6. **Multi-language consumers.** Today a non-ReScript consumer must hand-roll
   a parser. With CE, an off-the-shelf SDK in Go/Java/Python/Rust ingests
   events with one line.
7. **Audit / compliance pipelines.** CE schemas are the lingua franca for
   tools like AWS Audit Manager, Splunk's CE input, and Datadog's Event
   Pipeline. Adopting CE lowers the integration cost for regulated
   deployments.

## 5. Alternative: Standardise the Envelope Without CloudEvents

If the cost of full CloudEvents adoption is too high, a middle path is to
**fix the format-design issues from §3 in-house** without adopting an external
spec:

- Introduce a typed `StoredEvent` schema used by both EventLog and DcbEventLog.
- Add `causationId`, `traceId`/`spanId`, `schemaVersion` to `Message.meta`.
- Make `ip` and `user` optional; replace `"unknown"` with `option<string>`.
- Persist meta in DcbEventLog (currently absent — see [companion §11](./event-field-naming-comparison.md#11-dcbeventlog-publishes-metadata-to-eventtopic-but-doesnt-persist-it)).
- Add an extensible `headers?: dict<string>` for tenant id / feature flags / etc.
- Distinguish producer time (`createdAt`) from storage time (`recordedAt`).
- Rename per [companion doc](./event-field-naming-comparison.md) recommendations.

This captures **most of CloudEvents' benefits internally** (typed envelope,
extensibility, causation, tracing) without paying the migration cost or the
naming cost (lowercase extensions).

The trade-off: we keep paying the **interop tax** — every external integration
needs a Reventless-aware decoder.

## 6. Recommendation

A two-phase path:

**Phase 1 — fix format-design issues, prepare for CE.** (Non-breaking-ish,
~weeks)

1. Introduce a typed `StoredEvent` schema unifying EventLog + DcbEventLog
   envelopes (resolves §3.1, §3.2).
2. Add `causationId`, optional `traceparent`, optional extensible `headers`
   (resolves §3.3 partially).
3. Make `ip` and `user` optional and stop emitting `"unknown"` sentinels
   (resolves §3.4).
4. Persist meta in DcbEventLog (resolves [companion §11](./event-field-naming-comparison.md#11-dcbeventlog-publishes-metadata-to-eventtopic-but-doesnt-persist-it)).
5. Apply the [field renames from the companion doc](./event-field-naming-comparison.md#summary-of-recommendations).

**Phase 2 — opt-in CloudEvents wire format.** (Breaking storage change,
~quarter)

1. Define a bidirectional mapping between the typed `StoredEvent` and a
   CloudEvents 1.0 JSON-format payload.
2. Add a per-EventLog config `wireFormat: Native | CloudEvents`. Default
   stays `Native`; new tables can opt into `CloudEvents`.
3. Build adapter support: HTTP+CE-structured for the API, SNS attributes for
   CE-binary, EventBridge `detail`-mapping for cross-account routing.
4. Provide a one-shot migration tool that rewrites a DynamoDB table from
   `Native` to `CloudEvents`.
5. Once one downstream tool is in active use (EventBridge schema registry
   or EventSourcingDB), promote `CloudEvents` to default for new Reventless
   apps.

Phase 1 is unambiguously net-positive — it's the existing, agreed
[naming-comparison work](./event-field-naming-comparison.md) plus the
envelope/causation/headers/typed-stored-event additions.

Phase 2 is a **conditional bet**: only worth it if at least one ecosystem
integration (EventBridge, Knative, EventSourcingDB, Dapr) is on the roadmap.
If no such integration is planned, the lowercase-extension naming, larger
payloads, and migration cost outweigh the marketing benefit. Keep CE on the
shelf as a "ready to adopt when there is a buyer" option.

## 7. References

- [CloudEvents 1.0 spec](https://github.com/cloudevents/spec/blob/v1.0.2/cloudevents/spec.md)
- [CloudEvents Sequence extension](https://github.com/cloudevents/spec/blob/main/cloudevents/extensions/sequence.md) — fits `seq` / `position` exactly
- [CloudEvents Distributed Tracing extension](https://github.com/cloudevents/spec/blob/main/cloudevents/extensions/distributed-tracing.md)
- [CloudEvents Partitioning extension](https://github.com/cloudevents/spec/blob/main/cloudevents/extensions/partitioning.md)
- Companion analysis: [event-field-naming-comparison.md](./event-field-naming-comparison.md)
- Related: [done/dcb-event-type-coupling.md](./done/dcb-event-type-coupling.md) — notes EventSourcingDB uses CloudEvents
- Code: `reventless/reventless-spec/src/types/Message.res`,
  `reventless/reventless-core/src/components/EventLog/EventLog_Operations.res:37-52`,
  `reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res:55-93`
