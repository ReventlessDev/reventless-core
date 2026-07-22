// Deploy-time QueryDb storage for the Postgres backend (B3.1) — the read-model
// analogue of `EventLogStorage_Postgres` / `DcbEventLogStorage_Postgres`.
//
// Creates NO DynamoDB table and NO AppSync data source: read-model state lives in
// Postgres (`qdb_<name>`, JSONB) and is written by the projection Lambdas via the
// runtime ops. Returns:
//   - `resources: []` — no stream, no direct AppSync resolvers (suppressed by
//     `QueryDbResolvers.Selectable` until B3.2's Lambda data source);
//   - `dataSourceName: ""` — nothing to attach resolvers to;
//   - `operations` — the Postgres op set bound to the shared `PgConnection` pool.
//     Schema setup is lazy (first operation), so nothing connects during
//     `pulumi up` — a real query only runs inside a Lambda at runtime.
//
// Selected by `QueryDbStorage.Selectable(Stream)` when `QueryDbBackend` holds a
// selection and the read model is not admin-exempt.

type api = Types.AppSync.api
type role = Types.AppSync.role

let make: ReventlessCore.QueryDb_Adapter.storageMaker<api, role> = (
  ~name,
  ~indexes,
  ~subIdField=?,
  ~ttl as _=?,
  ~api as _,
  ~apiRole as _,
  ~owner as _=?, ~opts as _,
) => {
  let operations = switch QueryDbBackend.get() {
  | Some({connectionConfig}) =>
    connectionConfig->Pulumi.Output.apply(config =>
      QueryDbStorage_Postgres_Runtime.opsFor(config, ~name, ~indexes, ~subIdField?)
    )
  | None =>
    // Selectable only routes here when a selection is set; guard defensively.
    JsError.throwWithMessage("QueryDbStorage_Postgres.make called without a QueryDbBackend selection")
  }
  {
    ReventlessCore.QueryDb_Adapter.resources: [],
    // B3.2b: the shared PgQueryResolver Lambda data source. Deferred — resolved
    // by PgQueryResolver_Builder.provision after every plugin is built (the
    // resolvers that read it are created even later, inside the schema-pushed
    // resourcesMaker). Same value for every Postgres read model.
    dataSourceName: PgQueryResolver_Builder.dataSourceName,
    operations,
  }
}
