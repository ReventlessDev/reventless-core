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
