// Typed cold-start core for the Aggregate Lambda entry point.
//
// The "typed core, thin shell" split (docs/plans/done/minimize-lambda-entrypoint-mjs-shell.md).
// The `.mjs` shell owns the untyped seams — reading `HANDLER_CONFIG`, the dynamic
// `import()` of user Spec/Behavior modules, and the functor wiring that consumes
// those runtime-loaded modules (`EventLog_Operations.Make`, `Aggregate_Callback.Make`,
// `CommandTopic_Callback.Make`). This module owns the one piece that is pure
// typed framework wiring: selecting and building the EventLog storage operations.
//
// The `.mjs` previously built these with positional `append(resolvedTable)` /
// `replay(...)` calls into the compiled runtime, and — crucially — assembled only
// FOUR of the six `EventLog_Adapter.operations` fields, silently dropping
// `latestSnapshot` / `writeSnapshot` on both the DynamoDB and Postgres paths. The
// deploy-time adapter (EventLogStorage_DynamoDb.res) wires all six. Typing the
// return as `EventLog_Adapter.operations` forces parity: the Lambda now matches
// the deploy-time adapter exactly. Snapshot ops are a no-op when snapshotting is
// disabled (the default) and correct when it is enabled — where the old shell
// would have called `undefined`.

// The `pgConnection` object as it arrives in `HANDLER_CONFIG` — the resolved
// `PgConnection.connectionConfig` ({host,port,database,username,secretArn}).
// Present iff this aggregate is Postgres-backed; `tableName` doubles as the
// Postgres `event_log.log_name` (all aggregates share one Postgres table).
type pgConnectionJson
external asConnectionConfig: pgConnectionJson => PgConnection.connectionConfig = "%identity"

let makeStorageOps = (
  ~tableName: string,
  ~pgConnection: option<pgConnectionJson>,
): ReventlessCore.EventLog_Adapter.operations =>
  switch pgConnection {
  | Some(pg) => EventLogStorage_Postgres_Runtime.opsFor(pg->asConnectionConfig, ~logName=tableName)
  | None =>
    let table: Util_DynamoDb_Runtime.resolvedTable = {
      id: "",
      name: tableName,
      arn: "",
      hashKey: "id",
    }
    {
      ReventlessCore.EventLog_Adapter.append: EventLogStorage_DynamoDb_Runtime.append(table),
      replay: EventLogStorage_DynamoDb_Runtime.replay(table),
      replayStream: EventLogStorage_DynamoDb_Runtime.replayStream(table),
      appendStream: EventLogStorage_DynamoDb_Runtime.appendStream(table),
      latestSnapshot: EventLogStorage_DynamoDb_Runtime.latestSnapshot(table),
      writeSnapshot: EventLogStorage_DynamoDb_Runtime.writeSnapshot(table),
    }
  }
