// Postgres change-feed relay runtime (B2.2).
//
// Drains a Postgres DCB log via `PgChangeFeed` and pushes each event — transformed
// into the `{id, meta, event}` shape the plugin EventCollector SQS handler
// consumes — onto that queue. The plugin EventCollector (`EventCollectorEntryPoint`)
// then drives the full fan-out: read-model projections, aggregate command topics,
// and the cross-plugin SNS EventTopic. See
// docs/plans/done/aws-postgres-change-feed-bridge.md.
//
// The transform reuses the canonical DynamoDB shape producers
// (`derivePartitionKey` + `buildJsonEvent'`) so the emitted body is byte-identical
// to the DynamoDB-stream path — the SQS handler cannot tell the difference.

/**
 * Transform one feed event into the EventCollector JSON body. Rebuilds the same
 * unmarshalled-item dict the DCB DynamoDB-stream decoder would see (id from the
 * partition tag, position, event type, data, decomposed meta) and runs it through
 * `buildJsonEvent'` — the exact decoder the SQS handler expects. Returns `None`
 * for a malformed event (mirrors `buildJsonEvent'`).
 */
let toEventCollectorJson = (
  event: ReventlessCore.DcbEventLog_Adapter.rawSequencedEvent,
  ~partitionTag: option<Reventless.DcbTag.derivedPartitionTag>=?,
): option<JSON.t> => {
  let item = Dict.make()
  item->Dict.set(
    "id",
    DcbEventLogStorage_DynamoDb_Runtime.derivePartitionKey(~partitionTag?, event.tags)
    ->JSON.Encode.string,
  )
  item->Dict.set("position", event.position->JSON.Encode.string)
  item->Dict.set("event", event.eventType->JSON.Encode.string)
  item->Dict.set("data", event.data)
  ReventlessCore.Message.decomposeMeta(event.meta)->Array.forEach(((key, value)) =>
    item->Dict.set(key, value)
  )
  Util_DynamoDbStream_Runtime.buildJsonEvent'(item)
}

/**
 * Drain a Postgres DCB log from its checkpoint on the given `pool` and relay its
 * events to the EventCollector via the injected `sendBatch`. Both `pool` and
 * `sendBatch` are injected (rather than hardcoding Secrets Manager / SQS) so the
 * whole drain→transform→send path is integration-testable against a plain local
 * Postgres (B2.4); the `relay` wrapper below builds the container pool for the
 * deployed Lambda. Returns the number of events processed.
 *
 * At-least-once by construction: `PgChangeFeed.drain` replays the last page on a
 * crash before checkpoint, and EventCollector projections are idempotent
 * (event-sourced), so re-delivery is safe.
 */
let relayWithPool = async (
  ~pool: ReventlessPostgres.PgDriver.pool,
  ~logName: string,
  ~subscriber: string,
  // ~partitionTagJson: the DCB log's partition tag, sury-encoded into HANDLER_CONFIG
  // by the relay builder (B2.3d). Parsed once via the shared derivedPartitionTagSchema
  // so the `id` the relay emits matches the DynamoDB-stream path. Absent → None (a
  // single-tag log derives the same id without it).
  ~partitionTagJson: option<JSON.t>=?,
  ~sendBatch: array<JSON.t> => promise<unit>,
): int => {
  let partitionTag =
    partitionTagJson->Option.map(json =>
      json->Reventless.Util_Sury.fromJson(Reventless.DcbTag.derivedPartitionTagSchema)
    )
  await ReventlessPostgres.PgChangeFeed.drain(pool, ~logName, ~subscriber, ~handle=async events => {
    let jsons = events->Array.filterMap(event => toEventCollectorJson(event, ~partitionTag?))
    if jsons->Array.length > 0 {
      await sendBatch(jsons)
    }
  })
}

/**
 * Deployed-Lambda entry: resolve the container-lifetime pool from the injected
 * `PgConnection.connectionConfig` (via Secrets Manager) and relay. Thin wrapper over
 * `relayWithPool`.
 */
let relay = async (
  ~config: PgConnection.connectionConfig,
  ~logName: string,
  ~subscriber: string,
  ~partitionTagJson: option<JSON.t>=?,
  ~sendBatch: array<JSON.t> => promise<unit>,
): int => {
  let pool = PgRuntime.poolFor(config)
  await relayWithPool(~pool, ~logName, ~subscriber, ~partitionTagJson?, ~sendBatch)
}

// ─── Classic (aggregate) event_log relay ───

/**
 * Transform one classic feed event into the EventCollector JSON body. The stored
 * `payload` IS the flat item the DynamoDB append would have put (id, position,
 * event, data, decomposed meta) — classic appends write the serialized event JSON
 * verbatim on both backends — so the transform is exactly the DynamoDB-stream
 * decoder and the SQS handler cannot tell the difference. Returns `None` for a
 * malformed row (mirrors `buildJsonEvent'`; snapshots live in a separate Postgres
 * table and never enter the feed).
 */
let toClassicEventCollectorJson = (
  event: ReventlessPostgres.EventLogChangeFeed.classicEvent,
): option<JSON.t> =>
  event.payload
  ->JSON.Decode.object
  ->Option.flatMap(Util_DynamoDbStream_Runtime.buildJsonEvent')

/**
 * Drain a classic Postgres `event_log` log from its checkpoint on the given `pool`
 * and relay its events to the EventCollector via the injected `sendBatch`. Same
 * injection seam and at-least-once semantics as `relayWithPool`.
 */
let relayClassicWithPool = async (
  ~pool: ReventlessPostgres.PgDriver.pool,
  ~logName: string,
  ~subscriber: string,
  ~sendBatch: array<JSON.t> => promise<unit>,
): int =>
  await ReventlessPostgres.EventLogChangeFeed.drain(
    pool,
    ~logName,
    ~subscriber,
    ~handle=async events => {
      let jsons = events->Array.filterMap(toClassicEventCollectorJson)
      if jsons->Array.length > 0 {
        await sendBatch(jsons)
      }
    },
  )

/**
 * Deployed-Lambda entry for a classic log. Thin wrapper over `relayClassicWithPool`.
 */
let relayClassic = async (
  ~config: PgConnection.connectionConfig,
  ~logName: string,
  ~subscriber: string,
  ~sendBatch: array<JSON.t> => promise<unit>,
): int => {
  let pool = PgRuntime.poolFor(config)
  await relayClassicWithPool(~pool, ~logName, ~subscriber, ~sendBatch)
}
