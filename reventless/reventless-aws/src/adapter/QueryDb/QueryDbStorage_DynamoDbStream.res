open QueryDbStorage_DynamoDb

type api = Types.AppSync.api
type role = Types.AppSync.role

/** ReadModel Spec.names for which a stream-enabled QueryDb was created in this deploy.
    Read by subscriptionInfraHook to decide which QueryDbs get a StateTopic Lambda. */
let streamRegistry: ref<Set.t<string>> = ref(Set.make())

let make: ReventlessCore.QueryDb_Adapter.storageMaker<api, role> = (
  ~name,
  ~indexes,
  ~subIdField=?,
  ~ttl=?,
  ~api,
  ~apiRole,
  ~opts,
) => {
  streamRegistry.contents->Set.add(name)
  let tags = AWS.Tags.make(~name, ReventlessCore.QueryDb.componentType)
  let table = Util_DynamoDbStream.makeTable(
    name,
    ~attributes=attributes(subIdField, indexes),
    ~rangeKey=?subIdField,
    ~globalSecondaryIndexes=indexes->globalSecondaryIndexes,
    ~ttl?,
    ~streamViewType=NEW_AND_OLD_IMAGES,
    ~tags,
    ~opts,
  )
  open QueryDbStorage_DynamoDb_Runtime
  {
    resources: [table->Util_DynamoDbStream.toResource(~tags=tags->Pulumi.Output.fromInput)],
    dataSourceName: dataSource(name, table, api, apiRole, opts).name,
    operations: table
    ->Util_DynamoDb.toResolvedTableOutput
    ->Pulumi.Output.apply(resolvedTable => {
      ReventlessCore.QueryDb.load: resolvedTable->load,
      loadStream: resolvedTable->loadStream,
      save: resolvedTable->save,
      saveBatch: resolvedTable->saveBatch,
      count: resolvedTable->count,
      delete: resolvedTable->delete,
      deleteBatch: resolvedTable->deleteBatch,
    }),
  }
}
