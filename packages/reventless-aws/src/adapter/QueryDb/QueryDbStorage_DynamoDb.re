open PulumiAws;
open DynamoDb.Table;
open ReventlessSpec.ReadModelSpec;

type api = Pulumi.Output.t(PulumiAws.AppSync.GraphQLApi.t);
type role = Pulumi.Output.t(PulumiAws.IAM.Role.t);

let make: Reventless.QueryDb.Adapter.storageMaker(api, role) =
  (~name, ~indexes, ~sortField=?, ~ttl=?, ~api, ~apiRole, ~opts) => {
    let globalSecondaryIndexes =
      indexes
      ->Belt.List.toArray
      ->Belt.Array.map(({index, sortField, projectionType}) =>
          (
            switch (projectionType) {
            | `ALL as projectionType
            | `KEYS_ONLY as projectionType =>
              GlobalSecondaryIndex.make(
                ~name=index,
                ~hashKey=index,
                ~rangeKey=?sortField,
                ~projectionType,
                (),
              )
            | `INCLUDE(includes) =>
              GlobalSecondaryIndex.make(
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
        )
      ->Pulumi.Input.wrap;

    let attributes =
      [
        [{"name": "id", "type": "S"}],
        sortField->Belt.Option.mapWithDefault([], sortField =>
          [{"name": sortField, "type": "S"}]
        ),
        indexes
        ->Belt.List.map(({index, _type, sortField}) =>
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
      ->Belt.List.toArray;

    let table =
      Util_DynamoDb.makeTable(
        name,
        ~attributes,
        ~rangeKey=?sortField,
        ~globalSecondaryIndexes,
        ~ttl?,
        ~opts,
      );

    // API resources
    let _dataSourceRolePolicy =
      IAM.(
        RolePolicy.make(
          ~name,
          ~args=
            RolePolicy.Args.make(
              ~policy=
                table##arn
                ->Pulumi.Output.apply(tableArn =>
                    RolePolicy.generatePolicy(
                      [|tableArn ++ "*"|],
                      "dynamodb:*",
                    )
                  )
                ->Pulumi.Output.asInput,
              ~role=
                apiRole
                ->Pulumi.Output.flatMap(role => role##id)
                ->Pulumi.Output.asInput,
              (),
            ),
          ~opts,
          (),
        )
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

    {
      resources: [|table->Util_DynamoDb.toResource|],
      dataSourceName: dataSource##name,
      load: table->QueryDbStorage_DynamoDb_Runtime.load,
      save: table->QueryDbStorage_DynamoDb_Runtime.save,
      saveBatch: table->QueryDbStorage_DynamoDb_Runtime.saveBatch,
      count: table->QueryDbStorage_DynamoDb_Runtime.count,
      delete: table->QueryDbStorage_DynamoDb_Runtime.delete,
    };
  };
