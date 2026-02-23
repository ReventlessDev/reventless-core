let make: Reventless.DcbEventLog_Adapter.storageMaker = (~name, ~indexes, ~opts) => {
  // Build attributes array from index names
  let tagAttributes = indexes->Array.map(indexName => {
    {
      PulumiAws.DynamoDb.Table.name: indexName,
      type_: "S",
    }
  })

  let attributes = Array.concat(
    [
      {PulumiAws.DynamoDb.Table.name: "id", type_: "S"},
      {PulumiAws.DynamoDb.Table.name: "position", type_: "S"},
    ],
    tagAttributes,
  )

  // Build Global Secondary Indexes from index names
  let globalSecondaryIndexes =
    indexes
    ->Array.map(indexName => {
      {
        PulumiAws.DynamoDb.Table.name: indexName,
        hashKey: indexName,
        rangeKey: "position",
        projectionType: PulumiAws.DynamoDb.Table.ALL,
        nonKeyAttributes: ?None,
      }->Pulumi.Input.make
    })
    ->Pulumi.Input.make

  // Create DynamoDB table
  // Note: Using "id" as partition key (required by Util_DynamoDb.makeTable)
  // All DCB events will use id="dcb" to keep them in a single partition
  let table = Util_DynamoDb.makeTable(
    name,
    ~attributes,
    ~rangeKey="position",
    ~globalSecondaryIndexes,
    ~tags=AWS.Tags.make(~name, Reventless.DcbEventLog.componentType),
    ~opts,
  )

  {
    resources: [table->Util_DynamoDb.toResource],
    operations: table
    ->Util_DynamoDb.toRuntimeTableOutput
    ->Pulumi.Output.apply(runtimeTable => {
      Reventless.DcbEventLog_Adapter.read: DcbEventLogStorage_DynamoDb_Runtime.read(runtimeTable),
      append: DcbEventLogStorage_DynamoDb_Runtime.append(runtimeTable),
    }),
  }
}
