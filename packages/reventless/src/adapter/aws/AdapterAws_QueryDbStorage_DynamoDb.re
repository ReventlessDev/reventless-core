open PulumiAws;

type api = PulumiAws.AppSync.GraphQLApi.t;
type role = PulumiAws.IAM.Role.t;

let make = (~name, ~indexes, ~sortField, ~api, ~apiRole, ~opts) => {
  let globalSecondaryIndexes =
    indexes
    |> Array.of_list
    |> Array.map(({View.index, sortField, projectionType}) =>
         switch (projectionType) {
         | `ALL as projectionType
         | `KEYS_ONLY as projectionType =>
           DynamoDb.Table.GlobalSecondaryIndex.make(
             ~name=index,
             ~hashKey=index,
             ~rangeKey=?sortField,
             ~projectionType,
             (),
           )
         | `INCLUDE(includes) =>
           DynamoDb.Table.GlobalSecondaryIndex.make(
             ~name=index,
             ~hashKey=index,
             ~rangeKey=?sortField,
             ~projectionType=`INCLUDE,
             ~nonKeyAttributes=includes,
             (),
           )
         }
       );

  let attributes =
    [
      [{"name": "id", "type": "S"}],
      sortField->Belt.Option.mapWithDefault([], sortField =>
        [{"name": sortField, "type": "S"}]
      ),
      indexes
      |> List.map(({View.index, _type, sortField}) =>
           [
             {"name": index, "type": _type},
             ...sortField->Belt.Option.mapWithDefault([], sortField =>
                  [{"name": sortField, "type": "S"}]
                ),
           ]
         )
      |> List.flatten,
    ]
    |> List.flatten
    |> Array.of_list;

  let tableName = name ++ "Table";
  let table =
    DynamoDb.Table.make(
      ~name=tableName,
      ~args=
        DynamoDb.Table.Args.make(
          ~attributes,
          ~hashKey="id",
          ~rangeKey=?sortField,
          ~billingMode=`PAY_PER_REQUEST,
          ~globalSecondaryIndexes,
          (),
        ),
      ~opts,
      (),
    );
  // API resources
  let _dataSourceRolePolicy =
    IAM.RolePolicy.make(
      ~name=name ++ "RolePolicy",
      ~action="dynamodb:*",
      ~resource=[|table##arn->Pulumi.Output.apply(arn => arn ++ "*")|], // including indexes
      ~role=apiRole##id,
      ~opts,
      (),
    );
  let dataSource =
    AppSync.DataSource.makeDynamoDBDataSource(
      ~name=name ++ "DataSource",
      ~api,
      ~table,
      ~serviceRole=apiRole,
      ~opts,
      (),
    );

  QueryDb.{
    resource: table->AdapterAws_Util_DynamoDb.toResource,
    dataSourceName: dataSource##name,
    load: table->AdapterAws_QueryDbStorage_DynamoDb_Runtime.load,
    save: table->AdapterAws_QueryDbStorage_DynamoDb_Runtime.save,
    delete: table->AdapterAws_QueryDbStorage_DynamoDb_Runtime.delete,
  };
};