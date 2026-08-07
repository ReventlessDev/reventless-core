// Classic event-log tables stream unconditionally. A stream costs nothing until it
// is consumed, and without one the `EventLogProvisioning` seam has nothing to hand
// a backend for a classic log while DCB logs (which always stream) work — a silent
// capability difference between two adapters presenting the same port. The
// non-streaming maker had no callers; `DynamoDb` stays as an alias so out-of-tree
// references keep compiling.
module DynamoDb = EventLogStorage_DynamoDbStream
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
