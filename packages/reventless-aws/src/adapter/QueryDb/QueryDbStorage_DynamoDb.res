open PulumiAws
open DynamoDb.Table
open ReventlessSpec.ReadModel_Spec

type api = Pulumi.Output.t<AppSync.GraphQLApi.t>
type role = Pulumi.Output.t<IAM.Role.t>

let globalSecondaryIndexes = indexes =>
  indexes
  ->Belt.Array.map(({index, projectionType} as indexConfig) => {
    let (projectionType, includes) = switch projectionType {
    | ALL as projection => (PulumiAws.DynamoDb.Table.ALL, None)
    | KEYS_ONLY as projection => (KEYS_ONLY, None)
    | INCLUDE(includes) => (INCLUDE, Some(includes))
    }
    {
      name: index,
      hashKey: indexConfig.idField->Belt.Option.getWithDefault(index),
      rangeKey: ?indexConfig.subIdField,
      projectionType,
      nonKeyAttributes: ?includes,
    }->Pulumi.Input.make
  })
  ->Pulumi.Input.make

let attributes = (sortField, indexes) =>
  [
    [{name: "id", type_: "S"}],
    sortField->Belt.Option.mapWithDefault([], sortField => [{name: sortField, type_: "S"}]),
    indexes
    ->Belt.Array.map(({index, type_} as indexConfig) =>
      [
        [{name: index, type_}],
        indexConfig.subIdField->Belt.Option.mapWithDefault([], sortField => [
          {name: sortField, type_: "S"},
        ]),
      ]->Belt.Array.concatMany
    )
    ->Belt.Array.concatMany,
  ]->Belt.Array.concatMany

let dataSource = (name, table, api, apiRole, opts) => {
  let _dataSourceRolePolicy = {
    IAM.RolePolicy.make(
      ~name,
      ~args={
        IAM.RolePolicy.policy: table.arn
        ->Pulumi.Output.apply(tableArn =>
          IAM.RolePolicy.generatePolicy([tableArn ++ "*"], "dynamodb:*")
        )
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

let make: Reventless.QueryDb_Adapter.storageMaker<api, role> = (
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
    ~tags=AWS.tags(~name, Reventless.QueryDb.componentType),
    ~opts,
  )

  open QueryDbStorage_DynamoDb_Runtime
  {
    resources: [table->Util_DynamoDb.toResource],
    dataSourceName: dataSource(name, table, api, apiRole, opts).name,
    operations: table
    ->Util_DynamoDb.toRuntimeTableOutput
    ->Pulumi.Output.apply(runtimeTable => {
      Reventless.QueryDb.load: runtimeTable->load,
      save: runtimeTable->save,
      saveBatch: runtimeTable->saveBatch,
      count: runtimeTable->count,
      delete: runtimeTable->delete,
      deleteBatch: runtimeTable->deleteBatch,
    }),
  }
}
