let make: ReventlessCore.DcbEventLog_Adapter.storageMaker = (
  ~name,
  ~indexes,
  ~partitionTag,
  ~crossPartitionTagKeys=[],
  ~opts,
) => {
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

  // Build Global Secondary Indexes from index names.
  //
  // Projection: `tag_composite` stays `ALL` — composite (multi-tag) decision
  // reads resolve events directly from it. The per-tag `tag_<key>` GSIs are
  // `KEYS_ONLY`: they have no reader today (single-tag reads use the base-table
  // partition), and a future cross-partition secondary-tag read (Phase 7) goes
  // `Query` (keys) → `BatchGetItem` (payloads against the base table). KEYS_ONLY
  // drops the per-GSI event-payload storage multiplier and most of the per-write
  // WCU while keeping the index queryable. See docs/plans/dcb-consistency-hardening.md
  // Phase 3.
  let globalSecondaryIndexes =
    indexes
    ->Array.map(indexName => {
      let projectionType =
        DcbEventLogStorage_DynamoDb_Runtime.indexKeepsFullProjection(indexName)
          ? PulumiAws.DynamoDb.Table.ALL
          : PulumiAws.DynamoDb.Table.KEYS_ONLY
      {
        PulumiAws.DynamoDb.Table.name: indexName,
        hashKey: indexName,
        rangeKey: "position",
        projectionType,
        nonKeyAttributes: ?None,
      }->Pulumi.Input.make
    })
    ->Pulumi.Input.make

  // Create DynamoDB table with stream enabled — EventTopicPublisher_DynamoDbStream
  // needs a DynamoDbStream resource to connect the EventTopic.
  let tags = AWS.Tags.make(~name, ~kind=ReventlessCore.DcbEventLog.componentType, ~role=DcbEventLog, ~scope=Plugin)
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
      let readFn = DcbEventLogStorage_DynamoDb_Runtime.read(resolvedTable, ~crossPartitionTagKeys)
      {
        ReventlessCore.DcbEventLog_Adapter.read: readFn,
        append: DcbEventLogStorage_DynamoDb_Runtime.append(
          resolvedTable,
          ~partitionTag,
          ~crossPartitionTagKeys,
        ),
        readStream: DcbEventLogStorage_DynamoDb_Runtime.readStream(
          resolvedTable,
          ~crossPartitionTagKeys,
        ),
      }
    }),
  }
}
