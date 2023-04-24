open PulumiAws
open DynamoDb.Table
open ReventlessSpec.ReadModel.Spec

type api = Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>
type role = Pulumi.Output.t<PulumiAws.IAM.Role.t>

let globalSecondaryIndexes = indexes =>
  indexes
  ->Belt.List.toArray
  ->Belt.Array.map(({index, idField, subIdField, projectionType}) =>
    switch projectionType {
    | #ALL as projectionType
    | #KEYS_ONLY as projectionType =>
      GlobalSecondaryIndex.make(
        ~name=index,
        ~hashKey=idField->Belt.Option.getWithDefault(index),
        ~rangeKey=?subIdField,
        ~projectionType,
        (),
      )
    | #INCLUDE(includes) =>
      GlobalSecondaryIndex.make(
        ~name=index,
        ~hashKey=idField->Belt.Option.getWithDefault(index),
        ~rangeKey=?subIdField,
        ~projectionType=#INCLUDE,
        ~nonKeyAttributes=includes,
        (),
      )
    }->Pulumi.Input.make
  )
  ->Pulumi.Input.make

let attributes = (sortField, indexes) =>
  list{
    list{{"name": "id", "type": "S"}},
    sortField->Belt.Option.mapWithDefault(list{}, sortField => list{
      {"name": sortField, "type": "S"},
    }),
    indexes
    ->Belt.List.map(({index, _type, subIdField: sortField}) => list{
      {"name": index, "type": _type},
      ...sortField->Belt.Option.mapWithDefault(list{}, sortField => list{
        {"name": sortField, "type": "S"},
      }),
    })
    ->Belt.List.flatten,
  }
  ->Belt.List.flatten
  ->Belt.List.toArray

let dataSource = (name, table, api, apiRole, opts) => {
  let _dataSourceRolePolicy = {
    open IAM
    RolePolicy.make(
      ~name,
      ~args=RolePolicy.Args.make(
        ~policy=table["arn"]
        ->Pulumi.Output.apply(tableArn =>
          RolePolicy.generatePolicy([tableArn ++ "*"], "dynamodb:*")
        )
        ->Pulumi.Output.asInput,
        ~role=apiRole->Pulumi.Output.flatMap(role => role["id"])->Pulumi.Output.asInput,
        (),
      ),
      ~opts,
      (),
    )
  }

  AppSync.DataSource.makeDynamoDBDataSource(~name, ~api, ~table, ~serviceRole=apiRole, ~opts, ())
}

let make: Reventless.QueryDb.Adapter.storageMaker<api, role> = (
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
    ~opts,
  )

  open QueryDbStorage_DynamoDb_Runtime
  {
    resources: [table->Util_DynamoDb.toResource],
    dataSourceName: dataSource(name, table, api, apiRole, opts)["name"],
    load: table->load,
    save: table->save,
    saveBatch: table->saveBatch,
    count: table->count,
    delete: table->delete,
    deleteBatch: table->deleteBatch,
  }
}
