open QueryDbStorage_DynamoDb;

type api = Pulumi.Output.t(PulumiAws.AppSync.GraphQLApi.t);
type role = Pulumi.Output.t(PulumiAws.IAM.Role.t);

let make: Reventless.QueryDb.Adapter.storageMaker(api, role) =
  (~name, ~indexes, ~sortField=?, ~ttl=?, ~api, ~apiRole, ~opts) => {
    let table =
      Util_DynamoDbStream.makeTable(
        name,
        ~attributes=attributes(sortField, indexes),
        ~rangeKey=?sortField,
        ~globalSecondaryIndexes=indexes->globalSecondaryIndexes,
        ~ttl?,
        ~streamViewType=`NEW_AND_OLD_IMAGES,
        ~opts,
      );
    QueryDbStorage_DynamoDb_Runtime.{
      resources: [|table->Util_DynamoDbStream.toResource|],
      dataSourceName: dataSource(name, table, api, apiRole, opts)##name,
      load: table->load,
      count: table->count,
      save: table->save,
      saveBatch: table->saveBatch,
      delete: table->delete,
      deleteBatch: table->deleteBatch,
    };
  };
