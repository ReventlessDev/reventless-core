# Event Field Naming: Reventless vs. Industry Comparison

## Purpose

Compare the field names Reventless uses in its EventLog and DcbEventLog storage with established event sourcing products. Identify naming inconsistencies between the two components and opportunities to align with industry conventions.

## Current Reventless Field Names

### EventLog (aggregate-based, per-stream storage)

| Field | Type | Purpose |
|-------|------|---------|
| `id` | String (PK) | Aggregate ID |
| `sequenceNr` | String (SK) | Zero-padded position within the stream |
| `type` | String | Event variant name (e.g. `"ItemCreated"`) |
| `data` | Object | Event payload (variant fields, excluding TAG) |
| `service` | String | Service that produced the event |
| `time` | String | ISO-8601 timestamp |
| `ip` | String | Service instance IP |
| `user` | String | Originating user |
| `msgId` | String | Unique message identifier |
| `correlationId` | String | Upstream message ID for tracing |

Source: `EventLog_Operations.res:37-51`, `Message.res:26-40`

### DcbEventLog (DCB-based, single-partition append-only log)

| Field | Type | Purpose |
|-------|------|---------|
| `id` | String (PK) | Always `"dcb"` (single partition) |
| `position` | String (SK) | Timestamp-UUID global position |
| `eventType` | String | Event variant name (e.g. `"CategoryAdded"`) |
| `data` | Object | Event payload (variant fields, excluding TAG) |
| `tags` | Array | Content-based routing tags `[{key, value}]` |
| `tag_<field>` | String | secondary index attribute per tag field |
| `tag_composite` | String | secondary index attribute for multi-tag queries |

Source: `DcbEventLog_Adapter.res:1-12`, `DcbEventLogStorage_DynamoDb_Runtime.res:32-65`

## Industry Comparison

### How other products name the same concepts

| Concept | EventStoreDB | Axon | Marten | Eventuous | Prooph | Sequent | **EventLog** | **DcbEventLog** |
|---------|-------------|------|--------|-----------|--------|---------|-------------|----------------|
| **Event ID** | `eventId` | `eventIdentifier` | `id` | `message_id` | `event_id` | *(composite PK)* | `msgId` | *(none)* |
| **Event type** | `eventType` | `payloadType` | `type` | `message_type` | `event_name` | `event_type` | `type` | `eventType` |
| **Stream/Aggregate ID** | `eventStreamId` | `aggregateIdentifier` | `stream_id` | `stream_id` | *(in metadata)* | `aggregate_id` | `id` | *(N/A — single partition)* |
| **Stream position** | `eventNumber` | `sequenceNumber` | `version` | `stream_position` | *(in metadata)* | `sequence_number` | `sequenceNr` | *(N/A)* |
| **Global position** | `position` | `globalIndex` | `seq_id` | `global_position` | `no` | `xact_id` | *(N/A)* | `position` |
| **Payload** | `data` | `payload` | `data` | `json_data` | `payload` | `event_json` | `data` | `data` |
| **Metadata** | `metadata` | `metaData` | `headers` | `json_metadata` | `metadata` | *(none)* | *(flattened)* | *(none)* |
| **Timestamp** | `created` | `timeStamp` | `timestamp` | `created` | `created_at` | `created_at` | `time` | *(none)* |
| **Correlation ID** | in metadata | in metadata | `correlation_id` | in metadata | in metadata | *(none)* | `correlationId` | *(none)* |
| **Causation ID** | in metadata | in metadata | `causation_id` | in metadata | in metadata | `command_record_id` | *(none)* | *(none)* |

## Issues Identified

### 1. `type` vs `eventType` — inconsistent between EventLog and DcbEventLog

EventLog uses `type`, DcbEventLog uses `eventType` for the same concept (the event variant discriminator).

**Industry preference:** Split. EventStoreDB uses `eventType`, Marten uses `type`, Sequent uses `event_type`. The more explicit `eventType` is slightly more common and avoids ambiguity (`type` is a reserved word in many languages and could refer to anything).

**Recommendation:** Standardize on `eventType` in both components. It is more explicit, matches EventStoreDB (the dominant dedicated event store), and avoids the generic `type` name.

### 2. `sequenceNr` — abbreviation is uncommon

No other product abbreviates "number" as "Nr". Industry uses: `sequenceNumber` (Axon, Sequent), `eventNumber` (EventStoreDB), `version` (Marten), `stream_position` (Eventuous).

**Recommendation:** Rename to `sequenceNumber`. Matches Axon and Sequent, reads unambiguously. The abbreviation "Nr" may be confusing for international teams (common in German/Dutch, less so in English).

### 3. `id` as aggregate ID — too generic

Using bare `id` as the partition key for aggregate identity is ambiguous. In DcbEventLog, `id` is repurposed to always hold `"dcb"` — a different meaning entirely. Other products use descriptive names: `aggregateIdentifier` (Axon), `stream_id` (Marten, Eventuous), `aggregate_id` (Sequent).

**Recommendation:** Rename the EventLog partition key to `streamId`. This is a neutral term that works for both aggregate-based and non-aggregate stream partitioning, aligns with Marten/Eventuous naming, and eliminates the overloaded `id` that means different things in each component.

### 4. `time` — vague timestamp name

EventLog uses `time` for the creation timestamp. Industry prefers more descriptive names: `created` (EventStoreDB, Eventuous), `timestamp` (Marten), `created_at` (Prooph, Sequent), `timeStamp` (Axon).

**Recommendation:** Rename to `timestamp`. Matches Marten, is concise, and unambiguously refers to the event's creation time.

### 5. `msgId` — unclear abbreviation, confusing scope

`msgId` is the unique event identifier. No other product uses "message" terminology for event IDs — they use `eventId` (EventStoreDB), `eventIdentifier` (Axon), `event_id` (Prooph), or just `id` (Marten). The "msg" prefix is a Reventless implementation detail (events and commands share the `Message` module) that leaks into the storage schema.

**Recommendation:** Rename to `eventId`. Matches EventStoreDB, is self-descriptive, and doesn't expose internal abstractions.

### 6. Metadata is flattened in EventLog but absent in DcbEventLog

EventLog flattens metadata fields (`service`, `ip`, `user`, `msgId`, `correlationId`) as top-level DynamoDB attributes. DcbEventLog stores no metadata at all.

**Industry pattern:** Most products store metadata as a single blob/column (EventStoreDB, Axon, Eventuous, Prooph) or as optional dedicated columns (Marten). Only Reventless flattens metadata into the event record.

**Observation:** Flattening has a DynamoDB advantage (enables filtering/projections on individual fields without parsing JSON). However, the inconsistency between EventLog (has metadata) and DcbEventLog (no metadata) is a functional gap. DcbEventLog events cannot be correlated or audited.

**Recommendation:** Add metadata to DcbEventLog, stored either flattened (matching EventLog) or as a single `metadata` JSON field. At minimum, `eventId`, `timestamp`, and `correlationId` should be present for audit and tracing.

### 7. DcbEventLog lacks a timestamp

DcbEventLog has no stored timestamp — neither in the record fields nor in the adapter types. The `position` field (timestamp-UUID) encodes a timestamp implicitly, but it's not extractable as a human-readable field.

**Industry pattern:** Every product stores an explicit timestamp. It is universally considered essential for debugging, auditing, and time-based queries.

**Recommendation:** Add a `timestamp` field to DcbEventLog's stored record.

## Metadata Field Analysis

### How Reventless handles metadata today

**EventLog** stores metadata as flattened top-level DynamoDB attributes via `Message.decomposeMeta`:

| Field | Purpose | Required |
|-------|---------|----------|
| `service` | Name of the service that produced the event | Yes (always set) |
| `time` | ISO-8601 creation timestamp | Yes (auto-generated) |
| `ip` | IP address of the service instance | Yes (defaults to `""`) |
| `user` | Name of the acting user | Yes (defaults to `"unknown"`) |
| `msgId` | Unique identifier for this message | Yes (auto-generated UUID) |
| `correlationId` | ID of the upstream message that caused this one | Yes (defaults to `msgId` if not propagated) |

All six fields are required (non-optional) on the `Message.meta` record type. They are generated by `Message.generateMeta(~service, ~ip="", ~user="unknown")` which auto-fills `msgId` (UUID) and `correlationId` (copies `msgId`). Metadata is serialized via sury (`metaSchema`) and spread as top-level key-value pairs alongside `id`, `sequenceNr`, `type`, and `data`.

**DcbEventLog** stores **no metadata at all**. The `rawStoredEvent` type has only `eventType`, `data`, and `tags`. The `rawSequencedEvent` adds `position` but still no metadata. When DcbEventLog publishes to EventTopic, it generates a fresh `meta` for the message envelope — but this metadata is not persisted in the event store.

### How the industry handles metadata

#### Envelope vs. metadata boundary

Every product draws a line between **envelope** (structural fields the store needs to function) and **metadata** (contextual information about who/why/how).

| Framework | Envelope fields | Metadata approach |
|-----------|----------------|-------------------|
| **EventStoreDB** | `eventId`, `eventType`, `streamName`, `streamPosition`, `commitPosition`, `created`, `contentType` | Separate byte array, free-form (typically JSON). Convention: `$correlationId`, `$causationId`. `$`-prefix reserved for system. |
| **Axon** | `eventIdentifier`, `aggregateIdentifier`, `aggregateType`, `sequenceNumber`, `timeStamp`, `payloadType`, `payloadRevision` | `MetaData` map (`Map<String, Object>`), serialized to separate column. Auto-propagated: `correlationId`, `traceId`. Extensible via `CorrelationDataProvider`. |
| **Marten** | `id`, `seq_id`, `version`, `stream_id`, `type`, `mt_dotnet_type`, `timestamp`, `is_archived` | Opt-in columns: `correlation_id`, `causation_id`, `tenant_id`, user name. `headers` JSONB column for arbitrary key-value pairs. All disabled by default ("lean" mode). |
| **Eventuous** | Event type, stream name/position, content type, global position | Dictionary (flat key-value for cross-transport compat). Includes trace/span IDs (OpenTelemetry), correlation ID. Stored in backing store's metadata field. |
| **Prooph/Ecotone** | `no` (position), `event_id`, `event_name`, `created_at` | JSON `metadata` column. Framework-reserved `_`-prefixed keys: `_aggregate_id`, `_aggregate_type`, `_aggregate_version`, `_causation_id`, `_causation_name`. Extensible via `MetadataEnricher` pipeline. |
| **Sequent** | `aggregate_id`, `sequence_number`, `event_type`, `created_at` | No metadata bag. Causation tracked structurally via `command_record_id` FK. Custom data goes in event payload. |
| **Emmett** | `streamName`, `streamPosition`, `globalPosition` | Generic typed record (TypeScript generics). User defines their own metadata type per event. Framework merges with system metadata (positions). |
| **EventSauce** | `EVENT_ID`, `EVENT_TYPE`, `AGGREGATE_ROOT_ID`, `AGGREGATE_ROOT_TYPE`, `TIME_OF_RECORDING`, `AGGREGATE_ROOT_VERSION` | Flat `headers` map (string-string). Extensible via `MessageDecorator` chain. Built-in decorator adds standard headers. |

#### Correlation and causation patterns

| Pattern | Frameworks | How it works |
|---------|-----------|--------------|
| **Convention in free-form blob** | EventStoreDB | User puts `$correlationId` / `$causationId` in metadata bytes. System creates `$bc-<id>` streams. |
| **Auto-propagated typed fields** | Axon, Ecotone | Framework automatically copies correlation/trace IDs between messages. `correlationId` = parent message, `traceId` = root of the chain (Axon). Ecotone uses `correlationId` + `parentId`. |
| **Opt-in dedicated columns** | Marten | Separate PostgreSQL columns, created only when enabled. Auto-populated from OpenTelemetry spans. |
| **Enricher/decorator pipeline** | Prooph, EventSauce | Middleware-style: each enricher/decorator can add/modify metadata before persistence. |
| **Structural FK** | Sequent | `command_record_id` links events to the command that caused them. No correlation ID. |
| **User-defined typed metadata** | Emmett | User defines TypeScript type for metadata; framework merges with system fields at read time. |

#### Actor/user tracking

| Framework | Field | Notes |
|-----------|-------|-------|
| **Reventless EventLog** | `user` (always present, defaults `"unknown"`) | Flattened into event record |
| **Marten** | `LastModifiedBy` (opt-in column) | Must enable via `MetadataConfig` |
| **Prooph** | Custom enricher (e.g., `issued_by`) | No built-in; users implement `MetadataEnricher` |
| **EventSauce** | Custom decorator | No built-in; users implement `MessageDecorator` |
| **All others** | User-defined in metadata | No dedicated field; goes in generic metadata bag |

Observation: only Reventless and Marten have a named field for the acting user. Most frameworks leave this to user-defined metadata.

#### Service/origin tracking

| Framework | Field | Notes |
|-----------|-------|-------|
| **Reventless EventLog** | `service` + `ip` (always present) | Both flattened into event record |
| **All others** | Not built-in | Typically added via custom metadata or OpenTelemetry context |

Observation: Reventless is unique in storing `service` and `ip` as first-class metadata fields. In a microservice/serverless architecture these are valuable for debugging, but no other framework considers them important enough for built-in support. Most rely on OpenTelemetry or application-level metadata enrichment.

### Metadata storage patterns compared

| Pattern | Reventless EventLog | EventStoreDB | Axon | Marten | Prooph |
|---------|-------------------|-------------|------|--------|--------|
| **Storage format** | Flattened top-level attributes | Separate byte array | Serialized column | Opt-in columns + JSONB | JSON column |
| **Extensible** | No (fixed 6 fields) | Yes (any bytes) | Yes (map entries) | Yes (headers JSONB) | Yes (enricher pipeline) |
| **Queryable without parsing** | Yes (all fields are DynamoDB attributes) | No (must deserialize) | No (must deserialize) | Yes (dedicated columns) | No (must parse JSON) |
| **Overhead for events that don't need it** | Always stored | Only if set | Always (empty map) | Only if enabled | Always (empty JSON `{}`) |

### Issues specific to metadata

#### 8. Metadata is not extensible

Reventless's `Message.meta` is a fixed record with exactly six fields. There is no mechanism for users to attach custom metadata (tenant ID, trace ID, feature flags, request ID, etc.) without modifying the framework.

**Industry pattern:** Every other framework provides extensible metadata — either free-form (EventStoreDB), a typed map (Axon, Eventuous), opt-in columns + catch-all JSONB (Marten), or a decorator/enricher pipeline (Prooph, EventSauce).

**Recommendation:** Add an optional extensible metadata field. Two options:

1. **Add `headers?: dict<string>`** to `Message.meta` — flat string-string map, compatible with message brokers (SQS attributes, SNS attributes). Matches Eventuous's design rationale: brokers only support flat headers.
2. **Add `metadata?: JSON.t`** to `Message.meta` — rich structured metadata, matches EventStoreDB/Axon/Prooph. More flexible but less portable across transports.

Option 1 is recommended for Reventless's serverless context where events pass through SQS/SNS.

#### 9. `service` and `ip` are unusual metadata fields

No other event sourcing framework stores service name or IP address as first-class metadata. These are operational/infrastructure concerns typically handled by:
- OpenTelemetry: `service.name`, `net.host.ip` as span attributes
- CloudWatch / X-Ray: automatic service metadata in AWS
- Custom metadata enrichers: added at the application layer, not the framework layer

**Observation:** In a serverless (Lambda) context, `ip` is particularly questionable — Lambda instances have ephemeral IPs that provide no debugging value. `service` has more value but could be derived from the stream name or a deployment tag.

**Recommendation:** Consider deprecating `ip` (or making it optional) and moving `service` to an optional field. If users need these, they can use the extensible metadata mechanism from recommendation 8. This reduces mandatory metadata overhead and aligns with the principle that infrastructure concerns belong to the infrastructure layer, not the event store.

#### 10. No causation ID

Reventless has `correlationId` (which message started the chain) but no `causationId` (which specific message caused this one). This makes it impossible to reconstruct the exact message graph — you can group related messages but not trace parent-child relationships.

**Industry pattern:** Causation tracking is widely supported:
- EventStoreDB: `$causationId` convention
- Axon: `correlationId` actually serves as causation (parent message ID); `traceId` serves as correlation (chain root)
- Marten: `causation_id` opt-in column
- Prooph: `_causation_id` + `_causation_name`
- Ecotone: `parentId` (auto-propagated)
- Sequent: `command_record_id` FK

**Recommendation:** Add `causationId` to `Message.meta`. Set it to the `msgId` of the command that triggered the event. This enables full message graph reconstruction for debugging and audit.

#### 11. DcbEventLog publishes metadata to EventTopic but doesn't persist it

`DcbEventLog_Operations.res:52-53` generates fresh metadata when publishing to EventTopic:
```rescript
let meta = Message.generateMeta(~service=name)
try await Ops.publishJson(name, meta, json)
```

This means downstream consumers (read models, side effects) receive metadata, but the event store itself has no record of it. If an event needs to be replayed or audited, the metadata is lost.

**Recommendation:** Persist the same metadata that is published. Either store it in the DcbEventLog record alongside `eventType`/`data`/`tags`, or generate it at append time and pass it through to both storage and publish.

## Summary of Recommendations

### Field naming changes

| # | Current | Proposed | Scope | Breaking? |
|---|---------|----------|-------|-----------|
| 1 | EventLog: `type` | `eventType` | EventLog storage | Yes — storage migration |
| 2 | EventLog: `sequenceNr` | `sequenceNumber` | EventLog storage | Yes — storage migration |
| 3 | EventLog: `id` (aggregate) | `streamId` | EventLog storage | Yes — storage migration |
| 4 | EventLog: `time` | `timestamp` | EventLog storage + meta | Yes — storage migration |
| 5 | EventLog: `msgId` | `eventId` | EventLog storage + meta | Yes — storage migration |

### Metadata changes

| # | Current | Proposed | Scope | Breaking? |
|---|---------|----------|-------|-----------|
| 6 | DcbEventLog: no metadata | Add metadata (at minimum `eventId`, `timestamp`, `correlationId`) | DcbEventLog adapter + storage | Additive |
| 7 | DcbEventLog: no timestamp | Add `timestamp` field | DcbEventLog storage | Additive |
| 8 | `Message.meta`: fixed 6 fields | Add `headers?: dict<string>` for extensible metadata | Message type + both stores | Additive (optional field) |
| 9 | `Message.meta`: `ip` required | Make `ip` optional or deprecate | Message type + EventLog storage | Breaking (meta type change) |
| 10 | No causation tracking | Add `causationId` to `Message.meta` | Message type + both stores | Additive (optional field) |
| 11 | DcbEventLog: metadata generated for publish but not persisted | Persist metadata alongside event data | DcbEventLog operations + adapter | Additive |

### Migration Strategy

All EventLog renames are breaking changes to the DynamoDB storage format. Two approaches:

1. **Big-bang migration**: Write a one-time DynamoDB migration script that renames attributes in-place. Requires downtime or a blue-green deployment.
2. **Dual-read period**: Update the code to write new names but read both old and new. After all existing events have been migrated (or the table is recreated), remove the old-name read path.

DcbEventLog additions (timestamp, metadata) are non-breaking — new fields can be added to existing items without affecting reads of old items.

### Naming Convention Decision

The recommendations above use **camelCase** (e.g., `eventType`, `streamId`, `sequenceNumber`). This is consistent with:
- Reventless's existing ReScript/JavaScript conventions
- EventStoreDB's API naming
- DynamoDB's own API naming (e.g., `TableName`, `KeyConditionExpression`)

An alternative would be **snake_case** (e.g., `event_type`, `stream_id`), which aligns with Marten, Eventuous, Prooph, and Sequent. However, switching to snake_case would be a larger departure from Reventless's existing codebase style.

**Recommendation:** Keep camelCase for consistency with the existing codebase and JavaScript ecosystem.
