# Plan: Event-history query — the Source A read counterpart

**Date:** 2026-07-27
**Status:** IN PROGRESS

---

## Motivation

Reventless already reads its event logs three different ways, and **none of
them is reachable by an ordinary API client**:

| Path | Where | Shape | Reachable from the API? |
|---|---|---|---|
| `DcbEventLog.read` / `readStream` | `reventless/core/src/components/DcbEventLog/` | full `rawSequencedEvent` (position, eventType, data, tags, **meta**, recordedAt) | No — a runtime port, not an API |
| MCP `registerEventHistoryResourcesFromEntries` | [Platform.res:334](../../reventless/local/src/Platform.res#L334) | `{position, event, data, tags}` + cursor pagination | Only over MCP, and it **drops `meta`** |
| Source A subscription `on{N}EventLog_eventAppended` | [Plugin_SubscriptionSchema.res:80-97](../../reventless/core/src/plugin/component/Plugin_SubscriptionSchema.res#L80-L97) | `{position, eventType, payload}` | Yes, but **live-only** — no history, no actor, no time |

So the framework can answer "something was just appended" (the Source A
subscription) and "what happened, for an MCP client" (the resource handler),
but not "what happened to this entity, in order, with who and when" — the one
question an event-sourced system should be *best* at answering, and the shape
every audit, compliance and activity view is built out of.

For a client the gap is total: the only historical event access is over MCP,
so anything that is not an MCP client has no way to read an event log at all.
What such a client can see today is state — the read models — plus a live ping
when something changes. The history that produced that state, including who
caused each change and when, is not exposed.

The missing piece is small and well-bounded: **the query counterpart of the
Source A subscription**. Same event logs, same per-plugin generation point,
historical and paginated instead of live, and carrying the envelope `meta` that
the subscription omits.

## Scope

| Capability | In | Out |
|---|---|---|
| Per-plugin `…EventHistory` connection query, generated from `eventLogEntries` | ✅ | — |
| `meta` on the record (actor `user`, producer `time`, correlation/causation ids) | ✅ | — |
| Filters: entity tag, event types, actor, time range | ✅ | — |
| Keyset pagination over `sequencePosition` | ✅ | — |
| Local (yoga) resolver over `Bus.getEventLogReplay` / `Bus.getDcbEventLogRead` | ✅ | — |
| AWS (AppSync/Lambda) resolver | ✅ (staged — see Phase 4) | — |
| Authorization: the query inherits the plugin's existing identity plumbing | ✅ | Per-event field-level redaction |
| Decoded/typed event payloads per variant | — | Out — `payload` stays `AWSJSON`, exactly as the Source A subscription carries it |
| Cross-plugin "everything that happened" query | — | Out — per-plugin only, matching how every other generated query is scoped |
| Event *search* (full-text over payloads) | — | Out |

## Why a query and not "just widen the subscription"

A subscription cannot answer a historical question, and event history is
definitionally historical: it is read *after* the fact, by a caller who was not
connected at the time. The subscription is also deliberately lean — it is
documented "admin / observability only", a liveness ping. Adding actor and time
to it would make every appended event heavier for every subscriber, to serve a
case that needs a *page* of the *past*. Different questions; different fields.

---

## Background: the two event-log flavours

`eventLogEntries` is already the unified list — [Plugin_Builder.res:253-260](../../reventless/core/src/plugin/component/Plugin_Builder.res#L253-L260)
concatenates aggregate logs and DCB logs into one `array<eventLogSchemaEntry>`:

```rescript
type eventLogSchemaEntry = {
  busKey: string,
  displayName: string,
  eventSchema: S.t<unknown>,
}
```

That same array already drives both the Source A subscription fields and the
MCP event-history resources, so it is the right — and only — input this plan
needs. The two flavours differ only in how the runtime reads them, which the
MCP handler already demonstrates ([Platform.res:418-469](../../reventless/local/src/Platform.res#L418-L469)):

- **aggregate logs** → `Bus.getEventLogReplay(busKey)` → replay by entity id
- **DCB logs** → `Bus.getDcbEventLogRead(busKey)` → `read(~query)` filtered by tag

The resolver in Phase 3 reuses exactly this fork. Note the bug it must *not*
inherit: the MCP handler matches a log by
`resourceName->String.includes(entry.displayName->String.toLowerCase)`, a
substring match that mis-binds when one display name is a prefix of another
(`Order` vs `OrderLine`). The generated query keys off the display name
exactly, so the ambiguity cannot arise.

---

## Phase 1 — SDL generation (`Plugin_EventQuerySchema.res`)

New module beside `Plugin_SubscriptionSchema.res`, same signature style, same
call site.

```rescript
let generate = (~plugin: string, ~eventLogEntries: array<eventLogSchemaEntry>): result
// result = {queryFields: array<string>, extraTypes: array<string>}
```

Per distinct `displayName` (deduped exactly as `sourceAFieldsAndTypes` does):

```graphql
type EventMeta {
  service: String!
  time: String!
  user: String
  msgId: String!
  correlationId: String!
  causationId: String
}

type EventTag { key: String!, value: String! }

type {plugin}_{N}EventRecord {
  position: String!
  eventType: String!
  payload: AWSJSON!
  tags: [EventTag!]!
  meta: EventMeta!
  recordedAt: String!
}

type {plugin}_{N}EventRecordEdge { node: {plugin}_{N}EventRecord!, cursor: String! }
type {plugin}_{N}EventRecordConnection {
  edges: [{plugin}_{N}EventRecordEdge!]!
  pageInfo: PageInfo!
}

input {plugin}_{N}EventHistoryFilter {
  entityId: ID
  tagKey: String
  tagValue: String
  eventTypes: [String!]
  user: String
  timeFrom: String
  timeTo: String
}

# on Query:
{plugin}_{N}EventHistory(
  filter: {plugin}_{N}EventHistoryFilter
  first: Int, after: String, last: Int, before: String
): {plugin}_{N}EventRecordConnection!
```

Notes fixed here:

- `EventMeta` and `EventTag` are **shared** types emitted once per fragment and
  deduped by the stitcher across fragments, exactly like `commandResultSdlTypes`
  is today. `PageInfo` comes from the stitcher's relay base types.
- Record and filter type names are plugin-prefixed like every other generated
  type, so two plugins with a same-named event log cannot collide.
- `entityId` is the ergonomic filter (the common case: one record's history).
  It resolves against the aggregate id for aggregate logs, and against *any*
  tag value for DCB logs — the same semantics the MCP handler uses.
  `tagKey`/`tagValue` is the precise form for a DCB event carrying several ids
  where one specific one is meant.
- The connection is a Relay connection, identical in shape to every other list
  query in the API, so existing client pagination applies unchanged.
- `meta.ip`, `meta.traceparent`, `meta.headers`, `meta.schemaVersion` are
  deliberately **not** exposed. They are transport/tracing detail and, in the
  case of `headers`, a cross-cutting context bag (tenant ids, feature flags)
  that should not leave the server. `user` / `time` / correlation / causation
  are the audit-relevant subset.

## Phase 2 — Wire into the fragment

[Plugin_Builder.res:295-308](../../reventless/core/src/plugin/component/Plugin_Builder.res#L295-L308) already
composes the base fragment with the subscription result. The event-query result
folds in identically:

```rescript
let apiSchemaFragment = {
  let baseFragment = FragmentProvider.generateFragment(~mutationEntries, ~queryEntries)
  let subResult = Plugin_SubscriptionSchema.generate(~mutationEntries, ~eventLogEntries)
  let evtResult = Plugin_EventQuerySchema.generate(~plugin=name, ~eventLogEntries)
  let parts = GraphQL_Stitcher.decode(baseFragment)
  GraphQL_Stitcher.encode({
    ...parts,
    types: Array.flat([parts.types, subResult.extraTypes, evtResult.extraTypes]),
    queries: Array.concat(parts.queries, evtResult.queryFields),
    subscriptions: subResult.subscriptionFields,
    subscriptionSources: subResult.subscriptionSources,
  })
}
```

`Platform_Admin.res` gets the same treatment at its own fragment-assembly site
so platform-admin event logs are queryable too — that is where the plugin
lifecycle log lives, the one an operator most often needs a history of.

**Provider-neutral.** Like the Source A subscription SDL, nothing here is
AppSync-specific; each provider supplies its own resolver.

## Phase 3 — Local resolver

New `EventHistoryResolvers_GraphQL.res` under `reventless/local/src/adapter/`,
registered through a new `eventQueryResolverHook` on `Plugin_Helpers.hooks`
(mirroring `mcpSchemaRegistrationHook`, fired from `Plugin_Builder` with
`{pluginName, eventLogEntries}`).

Per entry, register one resolver that:

1. Forks on log flavour via `Bus.getEventLogReplay` / `Bus.getDcbEventLogRead`,
   as the MCP handler does — but **keeps `meta` and `recordedAt`**, which is
   the whole point.
2. Applies the filters in the order: tag/entity → event types → user → time
   range.
3. Sorts by `position` **numerically, not lexically**. The MCP handler already
   documents this trap at [Platform.res:377-381](../../reventless/local/src/Platform.res#L377-L381)
   ("10" > "9" is false as strings); the resolver must not re-introduce it.
   One comparison helper backs both the sort and the cursor bound.
4. Builds the Relay connection with `QueryDbListQuery.buildConnection`, so
   edges/cursors/pageInfo have the same shape as every other connection.
5. Registers its SDL field from the *same* generator that produced the
   fragment's field, so the local server's schema and the pushed fragment
   cannot drift on arguments or return type.

Identity comes from `extractIdentity(ctx)`, the same helper the QueryDb
resolvers use.

**Aggregate logs are per-entity only.** `replay` takes an id, so a filter-less
plugin-wide query over an aggregate log cannot be answered. The resolver logs a
warning naming the field and returns an empty connection, rather than implying
the log is empty.

## Phase 4 — AWS resolver (staged)

The SDL from Phase 1 lands in the pushed schema for AWS platforms as soon as
Phase 2 merges, so an AWS deployment gets the *field* immediately. The resolver
is a Lambda in the shape of `PgQueryResolver_Lambda` / the DCB read path,
reading the DynamoDB event-log table (aggregate logs) or the DCB table via
`DcbEventLog_Operations.read` with the built query.

Staged deliberately: land the schema and the local resolver, verify AWS at
deploy. A field with no resolver returns `null` on AWS until the Lambda ships,
so it must sit behind the same explicit capability gate other staged AWS
surfaces use — the field generated only when the platform advertises support,
rather than appearing as a permanently-null field in a deployed schema.

## Phase 5 — Tests

- `Plugin_EventQuerySchemaTest.res` — SDL shape, dedup by display name, shared
  types emitted once, plugin prefixing, and no `headers`/`ip`/`traceparent`
  leak.
- Resolver tests over the pure core (filter matching, argument decoding,
  keyset pagination): entity filter, precise tag pair, event-type filter, user
  filter, inclusive time range, filter composition, and a **position-ordering
  test that crosses a digit boundary** (positions 9 → 10) — the regression the
  numeric-comparison note above exists to prevent.

---

## Risks / open points

- **Payload shape is per-variant.** `payload` is opaque `AWSJSON`. Typed
  per-variant payloads would need one GraphQL union per event log — a large
  surface for little gain while consumers read them structurally. Revisit if a
  consumer needs to filter *inside* payloads.
- **Volume.** An entity's history pages fine, but a filter-less plugin-wide
  query over a large DCB log reads a lot. The connection's default page size
  (50, from `QueryDbListQuery.defaultListPageSize`) bounds the response, but
  not the underlying read on the DCB path, which filters in memory after
  `read(~query=[])`. The tag filter is therefore pushed into the DCB query
  (`[{tags: [{key, value}]}]`) whenever `entityId`/`tagValue` is supplied — so
  only the unfiltered plugin-wide sweep is ever broad.
- **Authorization granularity.** The query is gated at the plugin level like
  every other generated query. An event log can contain events about entities
  the caller cannot read through the read model, so a plugin with per-entity
  access rules gets a leak the read model does not have. Out of scope here, but
  it must be stated loudly in the guide: **exposing event history is an
  access-control decision**, and the generated field should be suppressible per
  plugin.
