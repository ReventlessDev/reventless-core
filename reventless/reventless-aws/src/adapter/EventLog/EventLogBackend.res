// AWS-side selection for the classic (aggregate) EventLog storage backend — the
// aggregate analogue of `DcbBackend` (B2.3c).
//
// When `Platform.MakeWithConfig` is given a `~pgConnection`, it records the resolved
// selection here BEFORE any admin/plugin `construct` runs. Read by:
//   - `EventLogStorage.Selectable` — route classic EventLog storage to Postgres (no
//     DynamoDB table/stream) and bind the Postgres operation set;
//   - `Aggregate_Builder_Single(_Async)` — substitute the stable `event_log.log_name`
//     for the DynamoDB table name registered with the runtime builder;
//   - `AggregateRuntime_Builder_Single(_Async).finish()` — inject `pgConnection` into
//     each handler's HANDLER_CONFIG entry (activates the AggregateEntryPoint.mjs
//     Postgres branch) and put the AllAggregates Lambda in-VPC with secret access;
//   - `Platform.provisionPgChangeFeedRelay` — relay each classic `event_log` log to
//     its plugin's EventCollector SQS queue.
//
// All classic EventLogs in the platform share one selection, mirroring the DCB
// toggle. Only the Single (sync/async) aggregate strategies honour it; the
// PerAggregate and Micro strategies stay DynamoDB-only.

type selection = {
  connectionConfig: Pulumi.Output.t<PgConnection.connectionConfig>,
  /** DB-access security group every aggregate/relay Lambda attaches (PgConnection.securityGroupId). */
  securityGroupId: Pulumi.Output.t<string>,
  /** Private subnets for the in-VPC aggregate/relay Lambdas (PgConnection.subnetIds). */
  subnetIds: array<Pulumi.Input.t<string>>,
}

let selectionRef: ref<option<selection>> = ref(None)

/** Record the classic-EventLog Postgres selection. Called once by the platform before construct. */
let set = (sel: selection) => selectionRef := Some(sel)

/** The active classic-EventLog Postgres selection, if the platform was given a `PgConnection`. */
let get = (): option<selection> => selectionRef.contents

/** Whether classic EventLog storage is Postgres-backed on this platform. */
let isPostgres = (): bool => selectionRef.contents->Option.isSome

// ---------------------------------------------------------------------------
// Relay-log registry — classic counterpart of DcbBackend's (B2.3d).
//
// One entry per Postgres-backed classic log (one per aggregate), assembled across
// the plugin build in two steps so `makePlatform` can provision the change-feed
// relay from complete inputs:
//   1. `EventLogStorage_Postgres.make` registers `{logName, aggregateName}` when
//      the classic storage is created (logName = `<Aggregate>EventLog`, the
//      ComponentType-derived name the deploy-time ops and the entry point share).
//   2. `PluginRuntime_Builder.forPluginEventCollector` attaches that plugin's
//      EventCollector SQS queue — its `~eventTopics` dict is keyed by aggregate
//      name, so each key attaches exactly the logs whose DynamoDB stream the
//      collector would have subscribed to on the DynamoDB path.
// ---------------------------------------------------------------------------
type relayLogEntry = {
  logName: string,
  aggregateName: string,
  mutable collectorQueueUrl: option<Pulumi.Output.t<string>>,
  mutable collectorQueueArn: option<Pulumi.Output.t<string>>,
}

let relayLogs: array<relayLogEntry> = []

/** Step 1: record a Postgres classic log (from the storage maker). */
let registerRelayLog = (~logName: string, ~aggregateName: string) =>
  relayLogs
  ->Array.push({logName, aggregateName, collectorQueueUrl: None, collectorQueueArn: None})
  ->ignore

/** Step 2: attach a plugin's EventCollector SQS queue to one aggregate's relay entry. */
let attachCollectorQueue = (
  ~aggregateName: string,
  ~url: Pulumi.Output.t<string>,
  ~arn: Pulumi.Output.t<string>,
) =>
  relayLogs
  ->Array.find(e => e.aggregateName == aggregateName)
  ->Option.forEach(e => {
    e.collectorQueueUrl = Some(url)
    e.collectorQueueArn = Some(arn)
  })

/** All registered relay logs (read by `makePlatform` to provision the relay). */
let getRelayLogs = (): array<relayLogEntry> => relayLogs
