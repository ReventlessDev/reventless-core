module DynamoDb = EventLogStorage_DynamoDb
module DynamoDbStream = EventLogStorage_DynamoDbStream
module DynamoDb_Runtime = EventLogStorage_DynamoDb_Runtime
module Postgres = EventLogStorage_Postgres

// Build-time classic storage selector — the aggregate analogue of
// `DcbEventLogStorage.Selectable`. Reads `EventLogBackend` — set by the platform
// when a `PgConnection` is supplied — and dispatches to Postgres (no table/stream)
// or the streamed DynamoDB maker. Used by the Single (sync/async) aggregate
// builders; PerAggregate and Micro stay on `DynamoDbStream` directly.
module Selectable = {
  let make: ReventlessCore.EventLog_Adapter.storageMaker = (~name, ~owner, ~opts) =>
    if EventLogBackend.isPostgres() {
      Postgres.make(~name, ~owner, ~opts)
    } else {
      DynamoDbStream.make(~name, ~owner, ~opts)
    }
}
