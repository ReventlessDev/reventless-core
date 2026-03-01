open QueryDbStorage_DynamoDb

type api = Types.AppSync.api
type role = Types.AppSync.role

let make: ReventlessCore.QueryDb_Adapter.storageMaker<api, role> = (
  ~name,
  ~indexes,
  ~subIdField=?,
  ~ttl=?,
  ~api,
  ~apiRole,
  ~opts,
) => {
  let table = Util_DynamoDbStream.makeTable(
    name,
    ~attributes=attributes(subIdField, indexes),
    ~rangeKey=?subIdField,
    ~globalSecondaryIndexes=indexes->globalSecondaryIndexes,
    ~ttl?,
    ~streamViewType=NEW_AND_OLD_IMAGES,
    ~tags=AWS.Tags.make(~name, ReventlessCore.QueryDb.componentType),
    ~opts,
  )
  open QueryDbStorage_DynamoDb_Runtime
  {
    resources: [table->Util_DynamoDbStream.toResource],
    dataSourceName: dataSource(name, table, api, apiRole, opts).name,
    operations: table
    ->Util_DynamoDb.toRuntimeTableOutput
    ->Pulumi.Output.apply(runtimeTable => {
      ReventlessCore.QueryDb.load: runtimeTable->load,
      loadStream: runtimeTable->loadStream,
      save: runtimeTable->save,
      saveBatch: runtimeTable->saveBatch,
      count: runtimeTable->count,
      delete: runtimeTable->delete,
      deleteBatch: runtimeTable->deleteBatch,
    }),
  }
}
