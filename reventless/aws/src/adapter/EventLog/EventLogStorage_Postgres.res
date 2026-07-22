// Deploy-time classic (aggregate) EventLog storage for the Postgres backend — the
// aggregate analogue of `DcbEventLogStorage_Postgres` (B2.3c).
//
// Creates NO DynamoDB table and NO stream: classic events live in Postgres
// (`event_log`, discriminated by `log_name`) and the shared `PgChangeFeedRelay`
// drives propagation. Returns:
//   - `resources: []` — so the aggregate's EventTopic `DynamoDbStream` publisher
//     becomes a passive marker with nothing to subscribe to, and
//   - `operations` — the classic runtime op set bound to the shared `PgConnection`
//     pool (lazy: no connection opens during `pulumi up`).
//
// Selected by `EventLogStorage.Selectable` when `EventLogBackend` holds a selection.

let make: ReventlessCore.EventLog_Adapter.storageMaker = (~name, ~owner as _, ~opts as _) => {
  // `name` is the ComponentType-derived `<Aggregate>EventLog` — the canonical
  // `event_log.log_name`. Register it so `makePlatform` can wire the change-feed
  // relay; the collector queue is attached later in forPluginEventCollector,
  // keyed by the aggregate name (the `~eventTopics` dict key).
  let aggregateName = name->String.endsWith("EventLog")
    ? name->String.slice(~start=0, ~end=name->String.length - 8)
    : name
  EventLogBackend.registerRelayLog(~logName=name, ~aggregateName)

  let operations = switch EventLogBackend.get() {
  | Some({connectionConfig}) =>
    connectionConfig->Pulumi.Output.apply(config =>
      EventLogStorage_Postgres_Runtime.opsFor(config, ~logName=name)
    )
  | None =>
    // Selectable only routes here when a selection is set; guard defensively.
    JsError.throwWithMessage("EventLogStorage_Postgres.make called without an EventLogBackend selection")
  }
  {
    ReventlessCore.EventLog_Adapter.resources: [],
    operations,
  }
}
