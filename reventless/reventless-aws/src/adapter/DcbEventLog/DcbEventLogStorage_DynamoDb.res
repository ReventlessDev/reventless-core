let make: ReventlessCore.DcbEventLog_Adapter.storageMaker = (~name, ~indexes, ~partitionTag, ~opts) => {
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

  // Create DynamoDB table with stream enabled — EventTopicPublisher_DynamoDbStream
  // needs a DynamoDbStream resource to connect the EventTopic.
  let tags = AWS.Tags.make(~name, ReventlessCore.DcbEventLog.componentType)
  let table = Util_DynamoDbStream.makeTable(
    name,
    ~attributes,
    ~rangeKey="position",
    ~globalSecondaryIndexes,
    ~streamViewType=NEW_IMAGE,
    ~tags,
    ~opts,
  )

  {
    resources: [table->Util_DynamoDbStream.toResource(~tags=tags->Pulumi.Output.fromInput)],
    operations: table
    ->Util_DynamoDb.toResolvedTableOutput
    ->Pulumi.Output.apply(resolvedTable => {
      let readFn = DcbEventLogStorage_DynamoDb_Runtime.read(resolvedTable, partitionTag)
      {
        ReventlessCore.DcbEventLog_Adapter.read: readFn,
        append: DcbEventLogStorage_DynamoDb_Runtime.append(resolvedTable, partitionTag),
        readStream: DcbEventLogStorage_DynamoDb_Runtime.readStream(resolvedTable, partitionTag),
      }
    }),
  }
}
