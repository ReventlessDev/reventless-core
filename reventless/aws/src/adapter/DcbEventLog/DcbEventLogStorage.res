module DynamoDb = DcbEventLogStorage_DynamoDb
module Postgres = DcbEventLogStorage_Postgres

// Build-time DCB storage selector (B2.3c). Reads `DcbBackend` — set by the platform
// when a `PgConnection` is supplied — and dispatches to Postgres (no table/stream) or
// DynamoDB. Passed to the Plugin / Admin functors in place of `.DynamoDb` so every DCB
// log follows the platform toggle, while aggregate EventLogs stay on DynamoDB.
module Selectable = {
  let make: ReventlessCore.DcbEventLog_Adapter.storageMaker = (
    ~name,
    ~indexes,
    ~partitionTag,
    ~crossPartitionTagKeys=[],
    ~opts,
  ) =>
    if DcbBackend.isPostgres() {
      Postgres.make(~name, ~indexes, ~partitionTag, ~crossPartitionTagKeys, ~opts)
    } else {
      DynamoDb.make(~name, ~indexes, ~partitionTag, ~crossPartitionTagKeys, ~opts)
    }
}
