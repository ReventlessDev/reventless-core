// Deploy-time DCB EventLog storage for the Postgres backend (B2.3c).
//
// Creates NO DynamoDB table and NO stream: DCB events live in Postgres (`dcb_event`)
// and the `PgChangeFeedRelay` drives propagation. Returns:
//   - `resources: []` — so the EventCollector wires no DynamoDB-stream ESM for this
//     log (the DCB EventTopic's `DynamoDbStream` publisher becomes a passive marker
//     with nothing to subscribe to), and
//   - `operations` — the runtime DCB op set bound to the shared `PgConnection` pool.
//
// Selected by `DcbEventLogStorage.Selectable` when `DcbBackend` holds a selection.
// The pool is lazy (`PgRuntime.poolFor`), so binding ops inside the deploy-time
// `Output.apply` opens no connection during `pulumi up` — a real query only runs
// inside the DcbCommandTopic Lambda at runtime. See
// docs/plans/done/aws-postgres-change-feed-bridge.md.

let make: ReventlessCore.DcbEventLog_Adapter.storageMaker = (
  ~name,
  ~indexes as _,
  ~partitionTag,
  ~crossPartitionTagKeys as _=[],
  ~opts as _,
) => {
  // B2.3d: `name` is the canonical `dcb_event.log_name` (`<plugin>DcbEventLog`).
  // Register it with its partition tag so `makePlatform` can wire the change-feed
  // relay; the collector queue is attached later in forPluginEventCollector.
  DcbBackend.registerRelayLog(~logName=name, ~partitionTag)

  let operations = switch DcbBackend.get() {
  | Some({connectionConfig, lockStrategy}) =>
    connectionConfig->Pulumi.Output.apply(config =>
      DcbEventLogStorage_Postgres_Runtime.opsFor(config, ~logName=name, ~lockStrategy)
    )
  | None =>
    // Selectable only routes here when a selection is set; guard defensively.
    JsError.throwWithMessage(
      "DcbEventLogStorage_Postgres.make called without a DcbBackend selection",
    )
  }
  {
    ReventlessCore.DcbEventLog_Adapter.resources: [],
    operations,
  }
}
