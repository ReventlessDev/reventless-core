open PulumiAws;

type api = Pulumi.Output.t(PulumiAws.AppSync.GraphQLApi.t);
type role = Pulumi.Output.t(PulumiAws.IAM.Role.t);

let make: Reventless.QueryDb.storageMaker(api, role) =
  (~name, ~indexes, ~sortField, ~api: api, ~apiRole: role, ~opts) => {
    let globalSecondaryIndexes =
      indexes
      ->Belt.List.toArray
      ->Belt.Array.map(({Reventless.View.index, sortField, projectionType}) =>
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
        )
      ->Pulumi.Input.wrap
      ->Pulumi.Input.wrap;

    let attributes =
      [
        [{"name": "id", "type": "S"}],
        sortField->Belt.Option.mapWithDefault([], sortField =>
          [{"name": sortField, "type": "S"}]
        ),
        indexes
        ->Belt.List.map(({Reventless.View.index, _type, sortField}) =>
            [
              {"name": index, "type": _type},
              ...sortField->Belt.Option.mapWithDefault([], sortField =>
                   [{"name": sortField, "type": "S"}]
                 ),
            ]
          )
        ->Belt.List.flatten,
      ]
      ->Belt.List.flatten
      ->Belt.List.toArray
      ->Pulumi.Input.wrap;

    let table =
      DynamoDb.Table.make(
        ~name,
        ~args=
          DynamoDb.Table.Args.make(
            ~attributes,
            ~hashKey="id"->Pulumi.Input.wrap,
            ~rangeKey=?sortField->Belt.Option.map(Pulumi.Input.wrap),
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
        ~name,
        ~action="dynamodb:*",
        ~resource=[|table##arn->Pulumi.Output.apply(arn => arn ++ "*")|], // including indexes
        ~role=apiRole->Pulumi.Output.flatMap(role => role##id),
        ~opts,
        (),
      );
    let dataSource =
      AppSync.DataSource.makeDynamoDBDataSource(
        ~name,
        ~api,
        ~table,
        ~serviceRole=apiRole,
        ~opts,
        (),
      );

    Reventless.QueryDb.{
      resource: table->Util_DynamoDb.toResource,
      dataSourceName: dataSource##name,
      load: table->QueryDbStorage_DynamoDb_Runtime.load,
      save: table->QueryDbStorage_DynamoDb_Runtime.save,
      delete: table->QueryDbStorage_DynamoDb_Runtime.delete,
    };
  };
