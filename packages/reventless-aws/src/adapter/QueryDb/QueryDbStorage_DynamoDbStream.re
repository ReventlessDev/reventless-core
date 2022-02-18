open PulumiAws;
open DynamoDb.Table;

type api = Pulumi.Output.t(AppSync.GraphQLApi.t);
type role = Pulumi.Output.t(IAM.Role.t);

let make: Reventless.QueryDb.Adapter.storageMaker(api, role) =
  (
    ~name,
    ~indexes,
    ~sortField,
    ~ttl,
    ~api: api,
    ~apiRole: role,
    ~opts,
    ~resources as _,
  ) => {
    let globalSecondaryIndexes =
      indexes
      ->Belt.List.toArray
      ->Belt.Array.map(({Reventless.View.index, sortField, projectionType}) =>
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

    let restoreConfig = Pulumi.Config.make(Some("restore"));
    let restoreSourceName =
      restoreConfig
      ->Pulumi.Config.getObject("tables")
      ->Belt.Option.flatMap(tables => tables->Js.Dict.get(name));
    let restoreDateTime = restoreConfig->Pulumi.Config.get("time");
    let restoreToLatestTime = restoreDateTime->Belt.Option.isNone;

    let table =
      make(
        ~name,
        ~args=
          Args.make(
            ~attributes,
            ~hashKey="id"->Pulumi.Input.wrap,
            ~rangeKey=?sortField->Belt.Option.map(Pulumi.Input.wrap),
            ~billingMode=`PAY_PER_REQUEST,
            ~streamEnabled=true,
            ~streamViewType=`NEW_AND_OLD_IMAGES,
            ~globalSecondaryIndexes,
            ~ttl=?
              ttl->Belt.Option.map(_ =>
                Args.TableTtl.make(
                  ~attributeName=
                    QueryDbStorage_DynamoDb_Runtime.purgeTimeAttributeName->Pulumi.Input.wrap,
                  ~enabled=true->Pulumi.Input.wrap,
                  (),
                )
                ->Pulumi.Input.wrap
              ),
            ~pointInTimeRecovery=
              Args.PointInTimeRecovery.make(~enabled=true)->Pulumi.Input.wrap,
            ~restoreSourceName=?
              restoreSourceName->Belt.Option.map(Pulumi.Input.wrap),
            ~restoreDateTime=?
              restoreDateTime->Belt.Option.map(Pulumi.Input.wrap),
            ~restoreToLatestTime=restoreToLatestTime->Pulumi.Input.wrap,
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

    {
      resource: table->Util_DynamoDbStream.toResource,
      dataSourceName: dataSource##name,
      load: table->QueryDbStorage_DynamoDb_Runtime.load,
      count: table->QueryDbStorage_DynamoDb_Runtime.count,
      save: table->QueryDbStorage_DynamoDb_Runtime.save,
      saveBatch: table->QueryDbStorage_DynamoDb_Runtime.saveBatch,
      delete: table->QueryDbStorage_DynamoDb_Runtime.delete,
    };
  };
