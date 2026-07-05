// AWS-side selection for the DCB EventLog storage backend (B2.3c platform toggle).
//
// When `Platform.MakeWithConfig` is given a `~pgConnection`, it records the resolved
// selection here BEFORE any admin/plugin `construct` runs. Read by:
//   - `DcbEventLogStorage.Selectable` — route DCB storage to Postgres (no DynamoDB
//     table/stream) and bind the Postgres operation set;
//   - the DCB-command runtime env builder — inject `PG_CONNECTION` so the B2.1
//     `DcbCommandTopicEntryPoint.mjs` Postgres branch activates;
//   - `Platform.makePlatform` — provision the `PgChangeFeedRelay` and feed the plugin
//     EventCollector SQS queue.
//
// All DCB logs in the platform share one selection (the confirmed B2.3c toggle);
// aggregate EventLogs are unaffected — they stay on DynamoDB until the classic
// `event_log` change feed lands (B2.5). See docs/plans/aws-postgres-change-feed-bridge.md.

type selection = {
  connectionConfig: Pulumi.Output.t<PgConnection.connectionConfig>,
  /** DB-access security group every DCB/relay Lambda attaches (PgConnection.securityGroupId). */
  securityGroupId: Pulumi.Output.t<string>,
  /** Private subnets for the in-VPC DCB/relay Lambdas (PgConnection.subnetIds). */
  subnetIds: array<Pulumi.Input.t<string>>,
}

let selectionRef: ref<option<selection>> = ref(None)

/** Record the DCB Postgres selection. Called once by the platform before construct. */
let set = (sel: selection) => selectionRef := Some(sel)

/** The active DCB Postgres selection, if the platform was given a `PgConnection`. */
let get = (): option<selection> => selectionRef.contents

/** Whether DCB storage is Postgres-backed on this platform. */
let isPostgres = (): bool => selectionRef.contents->Option.isSome

// ---------------------------------------------------------------------------
// Relay-log registry (B2.3d)
//
// One entry per Postgres-backed DCB log, assembled across the plugin build in two
// steps so `makePlatform` can provision the change-feed relay from complete inputs:
//   1. `DcbEventLogStorage_Postgres.make` registers `{logName, partitionTag}` when
//      the DCB storage is created (both are known there, AWS-side).
//   2. `PluginRuntime_Builder.forPluginEventCollector` attaches that plugin's
//      EventCollector SQS queue, keyed by the canonical `logName`
//      (`<plugin>DcbEventLog`), when the collector Lambda is built.
// Both run during the plugin's own `P.make()`, so every registered log ends the
// build with its collector queue attached. `makePlatform` then reads this and calls
// `PgChangeFeedRelay_Builder.make` once (shared relay, per-log checkpoints).
// ---------------------------------------------------------------------------
type relayLogEntry = {
  logName: string,
  partitionTag: Reventless.DcbTag.derivedPartitionTag,
  mutable collectorQueueUrl: option<Pulumi.Output.t<string>>,
  mutable collectorQueueArn: option<Pulumi.Output.t<string>>,
}

let relayLogs: array<relayLogEntry> = []

/** Step 1: record a Postgres DCB log and its partition tag (from the storage maker). */
let registerRelayLog = (~logName: string, ~partitionTag: Reventless.DcbTag.derivedPartitionTag) =>
  relayLogs
  ->Array.push({logName, partitionTag, collectorQueueUrl: None, collectorQueueArn: None})
  ->ignore

/** Step 2: attach a plugin's EventCollector SQS queue to its DCB log's relay entry. */
let attachCollectorQueue = (
  ~logName: string,
  ~url: Pulumi.Output.t<string>,
  ~arn: Pulumi.Output.t<string>,
) =>
  relayLogs
  ->Array.find(e => e.logName == logName)
  ->Option.forEach(e => {
    e.collectorQueueUrl = Some(url)
    e.collectorQueueArn = Some(arn)
  })

/** All registered relay logs (read by `makePlatform` to provision the relay). */
let getRelayLogs = (): array<relayLogEntry> => relayLogs
