// Typed cold-start core shared by the QueryDb-backed entry-point shells
// (ReadModelEntryPoint.mjs, StateViewSliceEntryPoint.mjs).
//
// The "typed core, thin shell" split (docs/plans/minimize-lambda-entrypoint-mjs-shell.md).
// The DynamoDB QueryDb operations were built in each shell with seven positional
// `load(table)` / `save(table)` / … calls into the compiled runtime, assembled
// into an object the shell then passes to the ReadModel/StateViewSlice callback
// functor. Typing the return as `QueryDb_Adapter.operations` makes that assembly
// compiler-checked: a field rename/reorder or a `QueryDbStorage_DynamoDb_Runtime`
// signature change is a build error, not a silent runtime break.
//
// The Postgres branch (`pgQdbOpsFor` + env-gated `withLiveUpdates`) and the
// id-injection wrappers (`mkInjectIdSave`) stay in the shell: `pgQdbOpsFor` is
// already a single typed call, and the wrappers/live-update publishing are
// env-driven shell business logic, not framework-call drift.

let makeDynamoQueryDbOps = (~tableName: string): ReventlessCore.QueryDb_Adapter.operations => {
  let table: Util_DynamoDb_Runtime.resolvedTable = {
    id: "",
    name: tableName,
    arn: "",
    hashKey: "id",
  }
  {
    load: QueryDbStorage_DynamoDb_Runtime.load(table),
    loadStream: QueryDbStorage_DynamoDb_Runtime.loadStream(table),
    save: QueryDbStorage_DynamoDb_Runtime.save(table),
    saveBatch: QueryDbStorage_DynamoDb_Runtime.saveBatch(table),
    count: QueryDbStorage_DynamoDb_Runtime.count(table),
    delete: QueryDbStorage_DynamoDb_Runtime.delete(table),
    deleteBatch: QueryDbStorage_DynamoDb_Runtime.deleteBatch(table),
  }
}
