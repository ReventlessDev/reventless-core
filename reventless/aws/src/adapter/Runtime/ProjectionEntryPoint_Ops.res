// Typed QueryDb-assembly core shared by the two projection Lambda entry points
// (ReadModelEntryPoint.mjs, StateViewSliceEntryPoint.mjs).
//
// The "typed core, thin shell" split (docs/plans/done/minimize-lambda-entrypoint-mjs-shell.md):
// both shells build the QueryDb operation set (DynamoDB or Postgres, live-update
// wrapped) for each projection from spec-module reads; that machinery lives
// here, fully type-checked. The routed dispatch boundary they share (with the
// AutomationSlice entry point, which has no Postgres backend) lives in
// StreamRoutedEntryPoint_Ops — kept separate so this module's `pg`/PgRuntime
// imports stay out of the graphs that only need dispatch.
//
// Deliberately NOT folded into QueryDbEntryPoint_Ops: that module is also
// imported by DcbCommandTopicEntryPoint.mjs, and the Postgres branch here
// would drag `pg`/PgRuntime into the DCB command Lambda's cold-start graph.
//
// Runtime-pure: no `open PulumiAws` values — Pulumi appears in type positions
// only (erased).


// ── Runtime-loaded spec-module reads (typed at the seam) ────────────────────
// The shells read `config` / `subIdConfig` off dynamically imported spec
// modules; these are the shapes those reads are typed against. `indexes` is
// optional so a module whose `config` lacks the field degrades to `[]` exactly
// as the former JS `(config && config.indexes) || []` did.

type specConfig = {indexes?: array<Reventless.ReadModel.indexConfig>}

let indexesOf = (config: option<specConfig>): array<Reventless.ReadModel.indexConfig> =>
  config->Option.flatMap(c => c.indexes)->Option.getOr([])

let subIdFieldOf = (
  subIdConfig: option<Reventless.ReadModel.subIdConfig<JSON.t>>,
): option<string> => subIdConfig->Option.map(c => c.subIdField)

// ── QueryDb operations (DynamoDB / Postgres backend branch) ─────────────────
// `pgConnection`, when present, selects the Postgres QueryDb runtime for the
// projection's view table (`queryDbTableName` is then the spec name, the shared
// `qdb_<name>` discriminator). Absent → the DynamoDB operation set.
//
// On a subscription-enabled (Stream) Postgres projection, every save/delete
// also publishes a live-update descriptor (no DynamoDB stream exists).
// `stateTopicName` (present only for stream projections) + APPSYNC_ENDPOINT
// gate it; absent → withLiveUpdates returns the ops unchanged.

type liveConfig = {
  endpoint?: string,
  region?: string,
  topicName?: string,
  subIdField?: string,
}

@module("./StateTopicPublish.mjs")
external withLiveUpdates: (
  ReventlessCore.QueryDb_Adapter.operations,
  liveConfig,
) => ReventlessCore.QueryDb_Adapter.operations = "withLiveUpdates"

let makeQueryDbOps = (
  ~queryDbTableName: string,
  ~pgConnection: option<PgConnection.connectionConfig>,
  ~stateTopicName: option<string>,
  ~indexes: array<Reventless.ReadModel.indexConfig>,
  ~subIdField: option<string>,
): ReventlessCore.QueryDb_Adapter.operations =>
  switch pgConnection {
  | Some(connection) =>
    QueryDbStorage_Postgres_Runtime.opsFor(
      connection,
      ~name=queryDbTableName,
      ~indexes,
      ~subIdField?,
    )->withLiveUpdates({
      endpoint: ?(NodeProcess.env->Dict.get("APPSYNC_ENDPOINT")),
      region: ?(NodeProcess.env->Dict.get("AWS_REGION")),
      topicName: ?stateTopicName,
      subIdField: ?subIdField,
    })
  | None => QueryDbEntryPoint_Ops.makeDynamoQueryDbOps(~tableName=queryDbTableName)
  }
