# Event Envelope Standardisation (without CloudEvents)

> Status: Complete (ready to move to docs/plans/done/ after commit)
> Source: [docs/analysis/event-format-and-meta-review.md](../../analysis/event-format-and-meta-review.md) §5 ("Alternative: Standardise the Envelope Without CloudEvents") and §6 Phase 1.
> Companion: [docs/analysis/event-field-naming-comparison.md](../../analysis/event-field-naming-comparison.md)
>
> **Decisions locked in:** Q1 nested `meta:meta` + adapter-flatten · Q2 unify field name `position` · Q3 `schemaVersion` on `meta` · Q4 one `feat!:` PR · Q5 `headers?: dict<string>` optional.
>
> **Progress (all 7 steps complete):**
> - ✅ Step 1 — `meta` shape change in `reventless-spec`. Optional fields: `ip?`, `user?`, `causationId?`, `traceparent?`, `schemaVersion?`, `headers?`. `service`/`time`/`msgId`/`correlationId` stay required. `correlationId` keeps defaulting to `msgId`.
> - ✅ Step 2 — `generateMeta` / `decomposeMeta` / `composeMeta` updated in `reventless-core`; `Message.string` coalescing helper removed; new optional params on `generateMeta`; added `Message.deriveMeta(~parent, ~service=?)` for causation-aware derivation.
> - ✅ Step 3 — `StoredEvent` schema added (`reventless/reventless-spec/src/types/StoredEvent.res`) — flat `{id, position, event, data, meta, recordedAt, tags?}`. `Message.storedEventToFlatJson` / `flatJsonToStoredEvent` helpers in core for the meta-flattening bridge. `DcbTag.tag` got `@schema` for sury serialization.
> - ✅ Step 4 — EventLog uses `StoredEvent`. `seq` → `position` everywhere (encoder, DynamoDB table schema + range key, OCC condition `attribute_not_exists(position)`, MCP cursor, in-memory admin pagination, test fixtures).
> - ✅ Step 5 — DcbEventLog persists meta + recordedAt: `rawStoredEvent`/`rawSequencedEvent` (and infra-spec `rawEvent`/`rawSequencedEvent`) all carry `meta`, DCB SQLite schema has `meta TEXT NOT NULL, recorded_at TEXT NOT NULL`, DynamoDB `toItem` flattens `meta.*` (and writes `recordedAt`) alongside tags + GSI helpers; `fromItem` reads them back. `DcbEventLog_Operations.publishToEventTopic` no longer regenerates meta — uses per-event meta from `rawEvent.meta`, overrides only `service` to `<name>DcbEventLog` for routing.
> - ✅ Step 6 — causation propagation through every emission site I audited:
>   - `Aggregate_Callback.updateMeta` → `Message.deriveMeta(~parent=command'.meta)`.
>   - `StateChangeSlice_Callback.encodeEvent` → `Message.deriveMeta(~parent=parentMeta)` (service inherited; DcbEventLog publish overrides to `<name>DcbEventLog`).
>   - `EventMapper_Callback.createCommandJson` → `Message.deriveMeta(~parent=meta, ~service=Target.name)`.
>   - `Extension_Operations.forwardCommand` → `Message.deriveMeta(~parent=commandJson.meta)`.
>   - `AutomationSlice_Callback.makeMeta` / `InboundTranslationSlice_Callback.makeMeta` / `OutboundTranslationSlice_Callback.makeMeta` → use `Message.generateMeta` (parent context not threaded through phase1→phase2 today; documented as a follow-up).
>   - **Counter_Callback** + **PluginExtensionPoint_Plugin** + **CommandPublisher** intentionally remain on `generateMeta` (no parent message in context — they're chain roots).
>   - **API/ingress traceparent**: no central HTTP-to-command construction in framework code; documented as a recipe for resolver authors rather than framework code.
> - ✅ Step 7 — docs + tests:
>   - **docs**: `packages/doc/docs-framework/inner-workings/messages.md` Meta section rewritten with the new shape, `deriveMeta`, traceparent rationale, and the `headers` bag. `packages/doc/docs-framework/inner-workings/resources.md` updated `sequenceNr` → `position` in the example snippets. `docs/analysis/event-format-and-meta-review.md` §1 Current State rewritten to reflect the post-change shape; added §1.4 describing `StoredEvent`; renumbered the in-flight Pub/Sub section to §1.5.
>   - **tests**: 16 new tests added —
>     - `reventless-core/tests/message/MetaEnvelopeTest` (12 tests): optional-field omission, `generateMeta`/`deriveMeta` semantics, StoredEvent round-trip through the flat-dict bridge for both aggregate-style (no tags) and DCB-style (with tags), meta-flattening to top-level keys.
>     - `reventless-core/tests/aggregate/AggregateCausationTest` (4 tests): causation propagation through `Aggregate_Callback` — `event.meta.causationId == command.meta.msgId`, `correlationId` inherited, fresh `msgId`, service inherited.
>
> **Final state:** build clean (`pnpm run build 2>&1 | grep -E "Warning|warning|error|Error"` empty), all **1038 tests pass across 108 suites** (was 1022/106 before this work; +16 tests, +2 suites).

## Goal

Fix the **format-design** issues in the event/command envelope (typed stored-event schema, unify EventLog vs DcbEventLog, add causation/tracing/headers, optionalise `ip`/`user`, persist meta in the DCB log, split producer-time from storage-time) **without** adopting CloudEvents as the wire format. This is the "Phase 1" path from the analysis: unambiguously net-positive, no external-spec migration cost, no lowercase-extension naming cost.

CloudEvents adoption (Phase 2 of the analysis) is **explicitly out of scope** here — keep it on the shelf as a "ready when there is an ecosystem buyer" option.

## Scope

**In scope:**
1. A typed `StoredEvent` envelope schema, single source of truth for both EventLog and DcbEventLog on-disk records.
2. New `Message.meta` fields: `causationId`, `traceparent`, `schemaVersion`, extensible `headers` — all as optional record fields (`field?: T`).
3. Make `ip` and `user` optional record fields (`ip?: string`, `user?: string`); stop emitting the `""` / `"unknown"` sentinels.
4. Persist meta in `DcbEventLog` storage (currently absent — meta is re-generated at publish time only).
5. Distinguish producer time from storage time: `meta.time` (producer, unchanged) vs `StoredEvent.recordedAt` (storage, new).
6. PPX adjustments so `@@reventless.spec` / behavior injections still compile against the new `meta` shape.

**Out of scope (do not do here):**
- **Migration / read-compat.** All EventLogs and DcbEventLogs are recreated from scratch — there is no legacy on-disk data to read, translate, or migrate. No compat shims, no re-write tooling, no sentinel-meta synthesis for old records.
- **Field renames per the companion doc.** Selected renames have already been adapted and implemented separately; this plan does **not** rename existing fields. In particular `msgId`, `correlationId`, `service`, `time`, and the `event`/`data` storage columns stay as-is — see "Naming" below.
- CloudEvents wire format, EventBridge transport, Knative/Dapr packaging, EventSourcingDB adapter (analysis §4, §6 Phase 2).
- OpenTelemetry SDK wiring beyond carrying the `traceparent` string through the envelope (actual span creation/propagation is a separate plan).

**Naming — `msgId` stays (it's the right name for a shared envelope).**
`Message.meta` is embedded by **both** `event'<'id,'event>` and `command'<'id,'command>` (and `commandJson`). `msgId` is "the id of *this message*" — correct for an envelope that wraps either a command or an event. Renaming it to `eventId` would force splitting `meta` into separate command/event structures (or a base + extensions), which isn't worth it. (CloudEvents can use a bare `id` only because a CE envelope is per-event; ours is shared.) By the same logic, everything in `meta` is kept generic: `causationId`, `correlationId`, `traceparent`, `headers`, and `schemaVersion` (read as "version of *this message's* payload schema" — coherent for commands too) all apply to commands and events alike.

## Current state (baseline)

- `reventless/reventless-spec/src/types/Message.res` — `type meta = { service, time, ip, user, msgId, correlationId }`, all required. `event'<'id,'event> = { id, meta, event }`, `command'<'id,'command> = { id, meta, command }`, `commandJson = { id, meta, commandJson, delay? }`. No `StoredEvent` type — the on-disk shape only exists as inline `Dict` builds.
- `reventless/reventless-core/src/Message.res` — `generateMeta(~service, ~ip="", ~user="unknown")` fills `correlationId = msgId`; `decomposeMeta` / `composeMeta` flatten/unflatten meta to/from top-level attributes.
- `reventless/reventless-core/src/components/EventLog/EventLog_Operations.res` — `encodeEvent'` produces `{ id, seq, event, data, ...decomposeMeta(meta) }`; decode hand-picks `event` / `data` / meta keys.
- `reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res` — `toItem` produces `{ id, position, event, data, tags, tag_<key>, tag_composite }` — **no meta**. `fromItem` reads them back. `rawStoredEvent` has no `meta` field.
- `DcbEventLog_Operations.res:24` — re-generates meta at publish time so events reach the `EventTopic` with an envelope, but storage has none.

## Design

### D1. The `StoredEvent` envelope

Add to `reventless-spec` (new file `reventless/reventless-spec/src/types/StoredEvent.res`, or extend `Message.res`). **Flat** — no `storage` sub-record. Backend-specific extras are recognised optional/top-level fields, exactly as today's records lay them out:

```rescript
@schema
type tag = { key: string, value: string }   // (or reuse the existing DCB tag record)

@schema
type storedEvent<'id> = {
  /** Aggregate id (Aggregate-style) or synthesised partition key (DCB-style). Same as today's top-level `id`. */
  id: 'id,
  /** Sort key. EventLog: zero-padded sequence string (today's `seq`). DcbEventLog: "<unixMs>-<uuid>" (today's `position`). */
  position: string,
  /** Variant constructor name. KEEP this column name `event` — unchanged from today. */
  event: string,
  /** sury-encoded variant payload, TAG stripped. Today's `data` column, unchanged. */
  data: JSON.t,
  meta: meta,
  /** Storage timestamp (ISO-8601, ms), set by the storage adapter at append. NEW. */
  recordedAt: string,
  /** DCB-style only: the tag list. Absent for aggregate-style records. Today's `tags` array, unchanged. */
  tags?: array<tag>,
}
```

- `EventLog_Operations.encodeEvent'` and the DCB `toItem`/`fromItem` both go through `StoredEvent`'s sury schema instead of hand-built dicts. Encode and decode share one schema → no drift (§3.1).
- **`StoredEvent` *is* the on-disk shape** (modulo two DynamoDB-only index artifacts, below). The only "flattening" the adapter still does is for `meta` — keeping `meta.*` projected as top-level DynamoDB attributes so individual meta fields stay GSI-projectable (the §1.2 / §3.2 behaviour today). Whether `meta` is nested in the *type* and flattened by the adapter, or kept flat in the type too, is Q1 — but `position`, `event`, `data`, `tags` are flat in both the type and the item, no indirection.
- **DCB query attributes are unaffected.** The DynamoDB DCB adapter still: derives the partition key from `tags`/`partitionTag`; writes the `tag_<key>` attributes and `tag_composite` used by the tag GSIs; sorts by `position`. Those `tag_<key>` / `tag_composite` attributes are **pure DynamoDB index artifacts derived from `tags`** — they are *not* fields on `StoredEvent` (the in-memory backend doesn't need them; it filters the `tags` array directly). So every existing DCB query — `Query` on the tag-derived partition, GSI lookups on `tag_<key>`, range conditions on `position` — works exactly as before; nothing about the consistency-check append or the read path changes.
- Decision Q2: `seq` vs `position` — unify the *field name* (`position`, always a sortable string) while letting each backend keep its own value format. Don't try to make the values comparable across backends.

### D2. New `meta` fields

Use **optional record fields** (`field?: T`), not `field: option<T>`, for everything genuinely-optional — see "Optional fields vs `option` fields" below for why.

```rescript
@schema
type meta = {
  service: service,
  /** `time` stays as-is for the producer timestamp; `createdAt` is NOT introduced on meta
      (the producer-vs-storage pairing lives on StoredEvent.recordedAt). KEEP `time`
      to avoid a rename. */
  time: string,
  ip?: string,            // was: string (defaulted ""). Absent = unknown.
  user?: string,          // was: string (defaulted "unknown"). Absent = system/unknown.
  msgId: string,
  correlationId: string,  // REQUIRED — always has a value (defaults to msgId). Documented overload; not de-overloaded here.
  causationId?: string,   // NEW — direct parent message id; absent at chain root.
  traceparent?: string,   // NEW — W3C Trace Context header, opaque pass-through.
  schemaVersion?: string, // NEW — event-variant schema version stamp; absent = unversioned.
  headers?: dict<string>, // NEW — extensible bag: tenantId, feature flags, etc. Absent = empty; read via ->Option.getOr(Dict.make()).
}
```

Notes:
- `traceId`/`spanId` are derivable from `traceparent`; store the single `traceparent` string rather than two split fields (matches the W3C format and the CE distributed-tracing extension, keeps the door open for Phase 2). If a split is wanted later it's additive.
- **`traceparent` is intentionally all-lowercase** (not `traceParent`) — it's the literal W3C Trace Context HTTP header name, used verbatim by OpenTelemetry SDKs, the CloudEvents distributed-tracing extension, AWS X-Ray's HTTP binding, and every other system that propagates it. Storing it under the same spelling means adapters do zero case-translation between the HTTP header and the meta field, and event JSON in logs / CloudWatch reads identically to the trace context anywhere else. The breach of camelCase is deliberate, scoped to this externally-dictated name, and would apply equally to a future `tracestate` sibling.
- `headers` is `dict<string>?` (omitted from JSON when empty — saves bytes per record, which the analysis flags as real money at DynamoDB scale). Consumers normalise with `meta.headers->Option.getOr(Dict.make())`. (Alternative considered: non-optional `headers: dict<string>` defaulting to `{}` so consumers never branch — rejected for the per-record `{}` overhead. Open question Q5 if anyone wants to revisit.)
- `schemaVersion` could live on `meta` *or* on `StoredEvent` (it's really about the event, not the message). Open question Q3 — leaning `meta` for symmetry with how the event travels in-flight.
- `correlationId` is **not** renamed, **not** de-overloaded, and **stays required** — it always carries a value. (Renames are companion-doc scope, out of scope here.)

#### Optional fields vs `option` fields — why `field?: T`

- **No sury issue for record fields.** The known sury+`option` pitfall — `S.nullableAsOption` producing `T | undefined | null` that fails `jsonableValidation` (flag 16) — only occurs **inside union variants**, not plain object fields. For an object field, sury-ppx compiles `field?: T` and `field: option<T>` to effectively the same schema (`S.option(...)`, key omitted on `None`). Same wire form either way; the choice is purely ergonomic.
- **`field?: T` is cleaner on the wire** — the key is *absent* when unset, not present-as-`null` or present-as-`{}`. Smaller records, friendlier to non-Reventless consumers.
- **`field?: T` is far better with the PPX.** `@@reventless.spec`/`@@reventless.behavior` inject `meta`-typed values and behavior code builds `meta` literals; with optional fields neither injected nor user code must mention the new fields, whereas `option<T>` fields force every literal to write `causationId: None` etc. `commandJson.delay?: int` already follows this pattern. (reventless-ppx already emits `@res.optional` fields — they need `Location.none` on the attribute, a known constraint; Step 1's PPX work isn't new ground.)
- **Don't** apply this to fields that always have a value (`service`, `time`, `msgId`, `correlationId`) — those stay required.

### D3. `generateMeta` / `decomposeMeta` / `composeMeta`

- `generateMeta(~service, ~ip=?, ~user=?, ~causationId=?, ~traceparent=?, ~correlationId=?, ~headers=?)` — all new params optional. `ip` / `user` are simply omitted when not supplied (no `""` / `"unknown"` sentinel). `correlationId` still defaults to `msgId`.
- `decomposeMeta` / `composeMeta` updated for the new fields (just more keys; nothing conditional — we only ever read records this codebase wrote).
- The `Message.string` helper (the `Some(null) -> ""` coalescing for `ip`/`user`) is removed; with optional fields the schema does the right thing.

### D4. Producer-time vs storage-time

- `meta.time` stays the **producer** timestamp (no rename).
- `StoredEvent.recordedAt` is set by the **storage adapter** at append time (`Date.toISOString()` at the moment of the DynamoDB `PutItem` / batch write). For the aggregate EventLog this is in `EventLog_Operations` just before handing to `storage.append`; for the DCB log it's in `DcbEventLogStorage_DynamoDb_Runtime.toItem` (passed in).
- Lag = `recordedAt − meta.time` becomes observable for the first time. No alarm here — just make it available.

### D5. Persist meta in `DcbEventLog`

- Add `meta: Message.meta` (and `recordedAt: string`) to `DcbEventLog_Adapter.rawStoredEvent` (and the sequenced variant).
- `DcbEventLog_Operations` stops re-generating meta at publish time for stored events — the meta written at append time is the meta published to `EventTopic`. (Keep the publish-time path only for the synthetic case where there genuinely is none, if any remains.)
- `toItem` writes `meta.*` as flattened attributes (or a nested `meta` object — see Q1) **in addition to** the unchanged `id` / `position` / `event` / `data` / `tags` / `tag_<key>` / `tag_composite`; `fromItem` reads it all back via the `StoredEvent` schema.
- Resolves companion §11.

## Implementation steps

Ordered; each step should leave the build green (`pnpm run build 2>&1 | grep -E "Warning|warning|error|Error"` clean) and tests passing.

### Step 1 — `meta` shape change in `reventless-spec`
- Update `type meta` (D2). Update the TSDoc/`@example` blocks.
- Update `metaSchema` consumers in `Message.res` (spec) — `toEventSchema'`, `composeEventJson'`, etc. still compile (they reference `metaSchema` opaquely, so mostly free).
- **PPX:** check the `@@reventless.spec` / `@@reventless.behavior` injections that synthesise or pattern-match `meta`-typed values. Audit `reventless-ppx` for any literal `{service, time, ip, user, msgId, correlationId}` construction; the new optional fields are simply omitted from such literals (no change needed once they're `?:`). If the ppx itself emits any `?:` field, that attribute needs `Location.none` (known constraint). Rebuild `ppx-linux.exe` via Docker and commit both binaries (per repo convention) if anything in the ppx changes.
- Build the whole monorepo; fix fallout in `reventless-core`, `reventless-aws`, `reventless-in-memory`, examples.

### Step 2 — `generateMeta` / `decompose` / `compose` in `reventless-core`
- Implement D3. Remove the `Message.string` coalescing helper.
- Keep `generateMeta`'s existing positional/labelled call sites working (new params are optional with defaults).
- Update every `generateMeta` call site that passed `~ip` / `~user` — they still work; just confirm none relied on the `""`/`"unknown"` default value semantically (search for `== "unknown"` and `meta.user == ""` in the whole repo + reventless-ui — those are now `Some("unknown")` literal users vs `None` system, which is the *intended* fix, but flag each).

### Step 3 — `StoredEvent` schema
- Add `StoredEvent.res` (or extend `Message.res`) per D1 — flat, field `event` kept.
- Provide `StoredEvent.encode` / `decode` and, for the `meta`-flattening (Q1), `StoredEvent.toItemDict` / `fromItemDict` helpers in `reventless-core` that both the EventLog and DcbEventLog adapters share. The DCB adapter additionally synthesises `tag_<key>` / `tag_composite` from `tags` (unchanged code) before writing.

### Step 4 — EventLog uses `StoredEvent`
- Rewrite `EventLog_Operations.encodeEvent'` / decode to go through the `StoredEvent` schema (+ item-dict helper). `seq` → `position`; `event` column unchanged; `data` unchanged; `recordedAt` set here.
- No legacy decode path — encode and decode are the same `StoredEvent` schema, period.
- Update `EventPublish_Callback.publishedEvent` plumbing if the eventsJson shape it carries changes (it currently carries the flat dicts — keep that contract or version it).

### Step 5 — DcbEventLog uses `StoredEvent` + persists meta
- Add `meta` (and `recordedAt`) to `DcbEventLog_Adapter.rawStoredEvent` / `rawSequencedEvent`.
- `DcbEventLogStorage_DynamoDb_Runtime.toItem` now also writes `meta.*` (flattened or nested per Q1) + `recordedAt`, alongside the unchanged `id` / `position` / `event` / `data` / `tags` / `tag_<key>` / `tag_composite`. `fromItem` reads through `StoredEvent`. The partition-key derivation and tag GSIs are untouched.
- In-memory DCB adapter (`reventless-in-memory`) mirrors the change.
- `DcbEventLog_Operations` stops re-generating publish-time meta for stored events; threads the appended meta through to `EventTopic`. (`DcbEventLog_Operations.res:24`'s publish-time `generateMeta` call goes away — meta now flows from append.)
- Resolves companion §11.

### Step 6 — propagate `causationId` / `traceparent` / `headers` through the call chain
- Command handlers receive `Message.context = { id, meta }` — `meta.causationId` should be the *triggering command's* `msgId`; events emitted by a behavior should inherit `correlationId` from the command and set `causationId = command.msgId`. Audit where `event'` envelopes are constructed from command context (Aggregate_Callback, StateChangeSlice handlers, automation slices) and set `causationId` correctly. This is the one step with real semantic content, not mechanical.
- `headers` / `traceparent`: pass-through. Whatever arrives on the command's meta is copied to emitted events' meta unless overridden. API/ingress adapters populate `traceparent` from the inbound HTTP header if present (small addition to the API component's command construction).

### Step 7 — docs + tests
- Update `packages/doc` pages describing the event/command envelope and the EventLog/DcbEventLog record shapes.
- Update `docs/analysis/event-format-and-meta-review.md` §1 "Current State" once shipped (or note "see plan").
- Tests: see below.

## Testing

- **Round-trip:** `StoredEvent` encode→decode for both backends produces the original value.
- **EventLog:** `append` then `replay` returns events with full meta; optional fields absent unless set; `position` ordering is correct.
- **DcbEventLog:** append persists meta; `fromItem` reads it back through `StoredEvent`; tag GSIs still resolve; meta written at append equals meta published to `EventTopic`.
- **Causation propagation:** a command → behavior → event chain has `event.meta.causationId == command.meta.msgId` and `event.meta.correlationId == command.meta.correlationId`.
- **`ip`/`user` optionality:** `generateMeta()` with no `~ip`/`~user` serialises without those keys (no `""`/`"unknown"`); `generateMeta(~user="alice")` round-trips `Some("alice")`.
- **PPX:** the example plugins (`examples/online-shop-aggregates`, `online-shop-dcb`, `online-shop-hybrid`) compile and their `_GWT` tests pass.
- **In-memory parity:** `reventless-in-memory` E2E tests for EventLog / DcbEventLog updated and green.
- Zero compiler warnings after build.

## Compatibility

No on-disk migration — every EventLog and DcbEventLog is created fresh on the new schema. The only things to keep in mind:

- **Wire compat across a rolling deploy:** new `meta` fields are optional, so a producer on the new version and a consumer still on the old version interoperate (sury drops unknown fields on parse; missing optional fields decode as absent). Not a hard requirement given greenfield, but it's free.
- **Source-level breaking change:** `meta.user` / `meta.ip` go from "always a `string`" to "optional". Any code (in this repo or reventless-ui) doing `meta.user == "unknown"` to detect system messages must switch to checking the field is absent. Search and fix; this lands as `feat!:`.
- **`generateMeta` signature:** additive optional params — source-compatible.

## Risks / watch-items

- **PPX blast radius.** Touching `meta` ripples through every `@@reventless.spec`/`@@reventless.behavior` file via injection. Mitigate by making all new fields optional record fields so injected code that doesn't mention them still type-checks. Budget a Docker `ppx-linux.exe` rebuild + commit.
- **`publishedEvent` / `EventPublish_Callback` contract.** External-ish hook surface — changing the eventsJson shape it carries is observable. Prefer keeping its current flat-dict contract (built from `StoredEvent`) over changing it.
- **Causation semantics (Step 6).** Easy to get subtly wrong (e.g. setting `causationId` to the *event's own* id, or losing it across automation-slice hops). This step needs care and good tests; everything else is mechanical.
- **Don't accidentally do the renames.** This plan deliberately keeps `msgId`, `time`, `service`, `correlationId`, and the `event`/`data` storage columns as-is. If a reviewer asks "why not rename X here" — the answer is "renames are the companion doc's scope, the selected ones are already done, and `msgId` in particular is *correctly* generic because `meta` is shared by commands and events."

## Open questions

- **Q1 — `meta` flat in the type, or nested-and-flattened-by-the-adapter?** `StoredEvent` is flat for `id`/`position`/`event`/`data`/`tags` either way (decided). The remaining choice is just `meta`: keep `meta: meta` nested in the type and have the DynamoDB adapter flatten its keys to top-level item attributes (so meta fields stay GSI-projectable, matching today), or hoist the six-plus meta keys to top-level fields on `StoredEvent` itself. Nested-meta is cleaner for non-DynamoDB backends (in-memory, future S3/Postgres just store the object); flat-meta matches today's DynamoDB item 1:1 with no adapter step. **Leaning nested-meta + adapter-flatten.** (Note: `tag_<key>` / `tag_composite` are *not* part of this question — they're DynamoDB index artifacts the DCB adapter always synthesises from `tags`, never modeled on `StoredEvent`.)
- **Q2 — `seq` vs `position` value formats.** Confirmed unify the *field name* (`position: string`); do **not** attempt cross-backend ordering. OK?
- **Q3 — `schemaVersion` on `meta` or on `StoredEvent`?** It reads fine on `meta` as "version of this message's payload schema" (works for commands too), and `meta` is the only thing that travels in-flight on `EventTopic`. **Leaning `meta`.**
- **Q4 — does this land as one `feat!:` PR or staged?** Making `ip`/`user` optional (was always a string) is the only hard-breaking bit. Given greenfield it's probably fine to do it all in one `feat!:`; stage only if the diff gets unwieldy.
- **Q5 — `headers?: dict<string>` vs `headers: dict<string>` defaulting to `{}`?** Plan picks the optional form (omit when empty, consumers `->Option.getOr`). Revisit only if the per-call `Option.getOr` churn is judged worse than the per-record `{}` bytes.

## References

- [docs/analysis/event-format-and-meta-review.md](../../analysis/event-format-and-meta-review.md) — §3 (issues), §5 (this plan's basis), §6 Phase 1.
- [docs/analysis/event-field-naming-comparison.md](../../analysis/event-field-naming-comparison.md) — renames (out of scope here; selected ones already implemented), §10 (causationId), §11 (DcbEventLog doesn't persist meta).
- Code: `reventless/reventless-spec/src/types/Message.res`, `reventless/reventless-core/src/Message.res`, `reventless/reventless-core/src/components/EventLog/EventLog_Operations.res`, `reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res`, `reventless/reventless-core/src/components/EventLog/EventPublish_Callback.res`.
