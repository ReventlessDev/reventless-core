# Event Provenance & the `service` Overload — Originators for DCB Slices and Aggregates

> Date: 2026-07-09
> Companion to: [event-field-naming-comparison.md](./event-field-naming-comparison.md) (industry
> metadata comparison) and [event-format-and-meta-review.md](./event-format-and-meta-review.md)
> (envelope shape / CloudEvents). Trigger:
> [done/dcb-composite-query-clause-fence-contention.md](../plans/done/dcb-composite-query-clause-fence-contention.md).
>
> **Status:** Analysis / proposal. No code beyond the `originatorSlice` removal (below) has been
> written. This doc exists to decide *whether* and *how* to record event provenance
> consistently across aggregates and DCB slices, and *what to do about the overloaded
> `service` field*.

## 0. What triggered this

While chasing a composite-partition burst bug we found the framework was appending a
provenance tag — `{key: "originatorSlice", value: <sliceName>}` — to **every** DCB event's
`tags` array (in `StateChangeSlice_Callback.encodeEvent`). Its only purpose was to populate an
`originatorSlice: String` field on the admin event-log subscription
(`on{Name}EventLog_eventAppended`).

Carrying provenance through the **`tags`** array was the root cause of the bug: `tags` is for
*content-addressed routing/querying* (it drives partition keys, the `tag_composite` GSI, per-tag
GSIs, and consistency fences). The DynamoDB adapter computed `tag_composite` over *all* tags, so
the stored composite key became `…#originatorSlice:<slice>#…` while a composite decision **read**
built its key from the command's **entity** tags only — the two never matched, so a
composite-partition slice could never read back its own events (every re-sync read empty →
re-emitted a create → died on the create-guard fence → retries exhausted → read models stayed
empty).

**`originatorSlice` has been removed entirely** (no consumer read the subscription field; the
slice is derivable — see §4). This doc asks the follow-up the removal exposed: provenance *is*
legitimately useful for observability — where should it live, and should it be uniform across
aggregates and DCB?

## 1. The real problem: `meta.service` is overloaded

`Message.meta.service` is described as *"Name of the service that created or is addressed by this
message."* That "created **or** addressed" is the tell — it conflates two different concepts, and
the two event styles resolve it differently:

| | Aggregate events | DCB events |
|---|---|---|
| Who sets `service` | `CommandPublisher` / `CommandGenerator` set the **command** `service = AggregateSpec.name`; `Aggregate_Callback` inherits it into the event via `deriveMeta` | `DcbEventLog_Operations` **overwrites** `service = <plugin> ++ "DcbEventLog"` on every event before storage + publish |
| What `service` means | the aggregate — which happens to be **both** the producer **and** the projection-dispatch target | the **DCB event log** (the dispatch target) — **not** the producing slice |
| Is the producer recoverable from the stored event? | Yes: `service` == producing aggregate; also implied by the stream/partition id | **No**: `service` is the log; the producing slice identity is not stored anywhere (it *was* the removed `originatorSlice` tag) |

`service` is really a **dispatch/routing key**: EventCollector dispatch (`Plugin_Callback.handleJsonEvents`) keys on it, and a mismatch silently drops the event (see the runbook note in the project memory: *"meta.service doubles as projection dispatch key — tag with target aggregate's spec name; mismatch → silent no-op"*). For aggregates the producer and the dispatch target coincide, so `service` *accidentally* doubles as provenance. For DCB they diverge, so provenance had to be bolted on separately — via a tag, which caused the bug.

**So the inconsistency is not incidental; it is baked into `service` carrying two jobs.**

## 2. What an "originator" actually is (semantics)

The most important design constraint, and the one that rules out two tempting homes:

- **Originator = the component that produced *this specific* event.** It is a *point-in-time
  stamp*, set fresh by the producer for each event. It must **never be inherited** down a
  causation chain.
- Contrast with the fields that *are* the chain and *are* inherited/derived:
  - `correlationId` — root of the chain (inherited unchanged by `deriveMeta`).
  - `causationId` — the *direct* parent's `msgId` (re-derived each hop).
  These answer "what lineage led here"; the originator answers "who wrote this row." Orthogonal.

Consequences:

- **`meta.headers` is the wrong home.** `deriveMeta` copies `parent.headers` as-is
  ([Message.res](../../reventless/core/src/Message.res)), so an originator placed in
  `headers` would propagate downstream and mislabel every event whose producer didn't overwrite
  it. `headers` is also documented as a *caller/application* bag (tenantId, feature flags) that
  the framework never writes to today — putting framework provenance there is a category error.
- **`meta.service` is the wrong home** (for a *clean* producer identity) because it is already
  claimed by dispatch routing; the DCB override proves the two uses collide.

An originator therefore belongs on the **per-event write path**, stamped by whatever produces the
event (aggregate callback or slice callback), as a **dedicated field** — not a tag, not `headers`,
not `service`.

## 3. The `originatorSlice`-as-tag anti-pattern (why tags are off-limits)

DCB `tags` participate in, and would be polluted by, a provenance value in *five* places — only
the first caused the shipped bug, but all are latent:

1. `tag_composite` (multi-tag GSI key) — **the shipped bug**: write key ≠ read key.
2. `derivePartitionKey` for a `Simple`-no-`@partitionTag` spec picks `tags[0]` — a provenance tag
   ordered first would become the storage partition. (Today it's appended last, so this is latent,
   not live.)
3. Per-tag `tag_<key>` GSI attributes — a spurious `tag_originatorSlice` attribute on every row.
4. `appendUnconditional` bumps a fence per event tag → a spurious low-cardinality
   `fence#originatorSlice:<slice>` on the import/seed/replay path.
5. `readEventId` and other tag iterations had to special-case-filter it out.

The lesson generalises: **never put metadata in `tags`.** Tags are the content-addressed routing
surface; provenance is envelope metadata.

## 4. Is provenance even necessary? (derivability)

For DCB, the producing slice is **derivable** from the event type: each `StateChangeSlice`
declares its produced events (`Spec.event`), and `Dcb_Builder` already builds an
`eventType → producing slice` view (surfaced in the plugin structure's per-component `eventTypes`).
A subscription consumer holding an event's `eventType` can look up the producer.

Caveats (why derivability is not a free pass):
- **Uniqueness is convention, not enforced.** The framework *assumes* "a given event type is
  produced once" (`DcbTag.mergeTagKeysByEventType` comment); `DcbValidation` does **not** reject
  two slices in one boundary declaring the same event-type name. In practice slices own disjoint
  event types (the platform-inspector slices confirm this), so the lookup is reliable — but it is
  an unenforced invariant.
- It is a **lookup against schema**, not a value present on the event; an ad-hoc log viewer or an
  external consumer without the plugin structure can't resolve it.

For aggregates, the producer is likewise implied by `service` (== aggregate name) and the stream
id, so it is effectively always present there.

Net: provenance is *nice-to-have* observability, largely *derivable*, and currently *asymmetric*
(present-ish for aggregates via `service`, absent for DCB after the removal).

## 5. How other frameworks handle this

Folded from [event-field-naming-comparison.md](./event-field-naming-comparison.md) and extended
with the *producer/originator* angle specifically:

### 5.1 Producer / originating component

| Framework | Producer identity | Where | Set per event? Inherited? |
|---|---|---|---|
| **EventStoreDB** | none first-class | stream name encodes the category; producer via user metadata/OTel | n/a |
| **Axon** | `aggregateType` (+ `payloadType`) | **envelope columns** | per event; not inherited |
| **Marten** | `mt_dotnet_type` (the .NET event class) | envelope column | per event; not inherited |
| **Prooph/Ecotone** | `_aggregate_type` (+ `_aggregate_id`, `_aggregate_version`) | reserved metadata keys | per event; not inherited |
| **Sequent** | aggregate identity structural (per-aggregate rows) | table shape | n/a |
| **Eventuous / Emmett / EventSauce** | none built-in | user metadata / OTel resource attrs | n/a |

**Takeaway:** the closest industry analog to "which component produced this event" is
**Axon's `aggregateType` / Prooph's `_aggregate_type` / Marten's `mt_dotnet_type`** — a
*type-of-producer* stamp on the **envelope**, set per event, never inherited. Notably these are the
frameworks with an explicit aggregate model; none of them route it through a tag/query surface, and
the pure event-store products (EventStoreDB) and the newer TS ones (Emmett/Eventuous) don't store
it at all — they lean on **stream identity + OpenTelemetry** resource attributes.

### 5.2 `service` / origin service

Reventless is the **only** surveyed framework that stores a `service` (and historically `ip`) as
first-class event metadata. Everyone else treats "which service/process emitted this" as an
**operational** concern carried by OpenTelemetry (`service.name` resource attribute) or added ad
hoc via a metadata enricher — *not* as an event-store field, and *never* as a dispatch key.
Reventless's `service` is unusual precisely because it does double duty as the EventCollector
dispatch key.

### 5.3 Correlation / causation (the part everyone agrees on)

Every framework separates *lineage* from *producer*: correlation (chain root) + causation (direct
parent) are propagated/derived down the chain (Axon auto-copies `correlationId`/`traceId`; Ecotone
`parentId`; EventStoreDB `$correlationId`/`$causationId`; Marten opt-in columns; Sequent
`command_record_id` FK). Reventless already matches this with `correlationId` + `causationId`.
This confirms §2: provenance is a *different axis* from lineage and must not reuse the inherited
fields.

## 6. Options

### Option A — Do nothing (leave provenance out of DCB; derive when needed)
Keep the `originatorSlice` removal as the end state. Consumers that need "which slice produced
this" derive it from `eventType` + plugin structure (§4).
- **Pros:** zero new machinery; removes the bug class; matches EventStoreDB/Emmett (no producer
  field).
- **Cons:** the derivation leans on an unenforced uniqueness convention and needs the schema map;
  the aggregate/DCB asymmetry (aggregate provenance via `service`, DCB none) persists; no value
  present on the event for ad-hoc/external viewers.

### Option B — A uniform, dedicated `originator` on the envelope (recommended if we want provenance at all)
Add one optional field to `Message.meta` (or to `StoredEvent`), e.g. `originator?: string`,
holding the **producing component's spec name**, stamped fresh per event by **both**
`Aggregate_Callback` and `StateChangeSlice_Callback` (and any other producer: EventMapper,
translation slices). Never inherited by `deriveMeta` (it is set at production, not derivation).
Surface it on both event-log subscriptions uniformly.
- **Pros:** matches Axon/Prooph/Marten (`aggregateType`/`_aggregate_type`/dotnet type); guaranteed
  present and unambiguous (no convention/lookup); symmetric across aggregates and DCB; correct
  semantics (per-event, not inherited); keeps it **off** the tag surface (no bug class).
- **Cons:** touches the cross-cutting `meta`/`StoredEvent` shape and all three storage backends +
  both subscription schemas; adds a field most consumers won't read (though it's cheap and
  optional). If added to `meta` it must be explicitly excluded from `deriveMeta` inheritance (set
  fresh, not copied) — a small but important correctness detail.

### Option C — Disentangle `service` (the deeper fix, larger blast radius)
Split `service`'s two jobs: keep a **routing/dispatch key** (rename to e.g. `dispatchTarget` or
`eventSource`) distinct from a **producer identity** (`originator`, per Option B). Aggregates set
both to the aggregate name; DCB sets `dispatchTarget = <plugin>DcbEventLog` and
`originator = <slice>`.
- **Pros:** removes the root overloading; makes the aggregate/DCB behaviours principled rather than
  coincidental; the dispatch semantics stop silently depending on a field that also means
  "producer."
- **Cons:** `service` is load-bearing across the whole message/dispatch/publish stack (EventCollector
  keying, SNS routing, logs); renaming/splitting it is a broad, breaking change with a storage
  migration. Only worth it if the overloading causes further bugs.

## 7. Recommendation

1. **Keep `originatorSlice` removed** — provenance never belonged in `tags`, full stop. (Done.)
2. If provenance-for-observability is wanted as a *feature*, do **Option B**: one uniform,
   optional, per-event `originator` (producing component spec name) on the envelope, stamped by
   every producer, excluded from `deriveMeta` inheritance, surfaced identically on aggregate and
   DCB event-log subscriptions. This is the industry-aligned shape (Axon/Prooph/Marten) and fixes
   the asymmetry without reintroducing the tag-pollution class.
3. Treat **Option C** (`service` disentanglement) as a separate, deliberate item — record the
   overloading here so it's a known hazard, but don't fold a broad breaking rename into a
   provenance feature. Revisit if the `service`-as-dispatch-key overload bites again.
4. Regardless of B/C, **do not** use `meta.headers` for framework provenance (inherited → mislabels
   downstream) and **do not** use `tags` (content-addressed → pollutes routing/fences).

## 8. Open questions for the decision

- Do any *real* consumers (an event viewer, audit tooling) actually need producer-on-the-event, or
  is eventType-derivation (Option A) sufficient for the foreseeable roadmap?
- If Option B: field on `meta` (travels with every in-flight envelope, must be inheritance-excluded)
  vs. a storage-only `StoredEvent`/`recordedAt`-sibling attribute stamped by the storage layer
  (needs the producer name threaded to the adapter, but never risks inheritance)? The latter is
  semantically cleaner (pure storage provenance) but needs plumbing; the former is less plumbing but
  needs the explicit `deriveMeta` carve-out.
- Should `DcbValidation` start **enforcing** unique `eventType → producer` within a boundary? That
  would make Option A's derivation a guarantee rather than a convention, and is cheap to add.
