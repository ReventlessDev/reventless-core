open PulumiAws
open DynamoDb.Table

type api = Types.AppSync.api
type role = Types.AppSync.role

let globalSecondaryIndexes = (indexes: array<Reventless.ReadModel.indexConfig>) =>
  indexes
  ->Array.map((indexConfig: Reventless.ReadModel.indexConfig) => {
    let {index, projectionType} = indexConfig
    let (projectionType, includes) = switch projectionType {
    | Reventless.ReadModel.ALL as _projection => (PulumiAws.DynamoDb.Table.ALL, None)
    | Reventless.ReadModel.KEYS_ONLY as _projection => (
        PulumiAws.DynamoDb.Table.KEYS_ONLY,
        None,
      )
    | Reventless.ReadModel.INCLUDE(includes) => (
        PulumiAws.DynamoDb.Table.INCLUDE,
        Some(includes),
      )
    }
    {
      name: index,
      hashKey: indexConfig.idField->Option.getOr(index),
      rangeKey: ?indexConfig.subIdField,
      projectionType,
      nonKeyAttributes: ?includes,
    }->Pulumi.Input.make
  })
  ->Pulumi.Input.make

let attributes = (sortField, indexes: array<Reventless.ReadModel.indexConfig>) =>
  [
    [{name: "id", type_: "S"}],
    sortField->Option.mapOr([], sortField => [{name: sortField, type_: "S"}]),
    indexes
    ->Array.map((indexConfig: Reventless.ReadModel.indexConfig) => {
      let {index, type_} = indexConfig
      [
        [{name: index, type_}],
        indexConfig.subIdField->Option.mapOr([], sortField => [{name: sortField, type_: "S"}]),
      ]->Array.flat
    })
    ->Array.flat,
  ]->Array.flat

let dataSource = (name, table, api, apiRole, opts) => {
  let _dataSourceRolePolicy = {
    IAM.RolePolicy.make(
      ~name,
      ~args={
        IAM.RolePolicy.policy: table.arn
        ->Pulumi.Output.apply(tableArn => {
          open PolicyDocument
          PolicyDocument.make(
            ~id=name ++ "DataSourcePolicy",
            ~statements=[
              {
                sid: "AllowDynamoDbActions",
                effect: Allow,
                actions: Action("dynamodb:*"),
                resources: Resource(tableArn),
              },
            ],
          )->toJsonString
        })
        ->Pulumi.Output.asInput,
        role: apiRole
        ->Pulumi.Output.flatMap((role: PulumiAws.IAM.Role.t) => role.id)
        ->Pulumi.Output.asInput,
      },
      ~opts,
    )
  }

  AppSync.DataSource.makeDynamoDBDataSource(~name, ~api, ~table, ~serviceRole=apiRole, ~opts)
}

let make: ReventlessCore.QueryDb_Adapter.storageMaker<api, role> = (
  ~name,
  ~indexes,
  ~subIdField=?,
  ~ttl=?,
  ~api,
  ~apiRole,
  ~opts,
) => {
  let table = Util_DynamoDb.makeTable(
    name,
    ~attributes=attributes(subIdField, indexes),
    ~rangeKey=?subIdField,
    ~globalSecondaryIndexes=indexes->globalSecondaryIndexes,
    ~ttl?,
    ~tags=AWS.Tags.make(~name, ReventlessCore.QueryDb.componentType),
    ~opts,
  )

  open QueryDbStorage_DynamoDb_Runtime
  {
    resources: [table->Util_DynamoDb.toResource],
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
