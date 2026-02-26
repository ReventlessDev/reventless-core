let toInfo = (table: PulumiAws.DynamoDb.Table.t) =>
  (table.hashKey, table.rangeKey, table.streamArn)
  ->Pulumi.Output.all3
  ->Pulumi.Output.apply(((hashKey, rangeKey, streamArn)) =>
    hashKey ++ ("," ++ (rangeKey->Option.getOr("") ++ ("," ++ streamArn)))
  )

let streamArnFromDynamoDbTableResource = (resource: Reventless.Adapter.resource) =>
  (resource.info, resource.name)
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((tableInfo, tableName)) =>
    switch tableInfo->String.split(",") {
    | parts if parts->Array.length < 3 || parts->Array.getUnsafe(2)->String.trim == "" =>
      JsError.throwWithMessage("No streamArn field given for table " ++ tableName)
    | parts => parts->Array.getUnsafe(2)
    }
  )

let toResource = (table: PulumiAws.DynamoDb.Table.t): Reventless.Adapter.resource => {
  Reventless.Adapter.service: table.name->Pulumi.Output.apply(_ => AWS.DynamoDbStream.service),
  name: table.name,
  id: table.id,
  urn: table.arn,
  info: table->toInfo,
}

let toStreamResource = (table: Reventless.Adapter.resource): Reventless.Adapter.resource => {
  let streamArn = table->streamArnFromDynamoDbTableResource

  {
    Reventless.Adapter.service: table.name->Pulumi.Output.apply(_ =>
      AWS.DynamoDbStream.service
    ),
    name: table.name,
    id: streamArn,
    urn: streamArn,
    info: table.name->Pulumi.Output.apply(_ => ""),
  }
}

// Workaround when restore enabled: turn on stream, ttl & pointInTimeRecovery again
open AwsSdk.DynamoDb_DynamoDb

let enableStream = async tableName => {
  Console.log(`${__MODULE__}: enableStream for ${tableName}`)

  switch await UpdateTableCommand.make({
    tableName,
    streamSpecification: {
      streamEnabled: true,
      streamViewType: #NEW_IMAGE,
    },
  })->UpdateTableCommand.send {
  | res => (
      res.tableDescription.streamSpecification.streamEnabled,
      Some(res.tableDescription.latestStreamArn),
      res.tableDescription.latestStreamLabel,
    )
  }
}

let verifyStream = (table: PulumiAws.DynamoDb.Table.t) =>
  (table.name, table.streamEnabled, table.streamArn, table.streamLabel)
  ->Pulumi.Output.all4
  ->Pulumi.Output.flatMap(((tableName, streamEnabled, streamArn, streamLabel)) =>
    switch streamEnabled {
    | None
    | Some(false) =>
      enableStream(tableName)
    | Some(true) => (true, Some(streamArn), streamLabel)->Promise.resolve
    }->Pulumi.Output.fromPromise
  )

let updateTable: (~ttl: int=?, PulumiAws.DynamoDb.Table.table) => PulumiAws.DynamoDb.Table.table = (
  ~ttl=?,
  table,
) => {
  let streamInfo = verifyStream(table)

  let newTtl = Util_DynamoDb.verifyTtl(~expectedTtl=?ttl, table)
  let newPointInTimeRecovery = Util_DynamoDb.verifyPointInTimeRecovery(table)

  {
    ...table,
    streamEnabled: streamInfo->Pulumi.Output.apply(((enabled, _, _)) => Some(enabled)),
    streamArn: streamInfo->Pulumi.Output.apply(((_, streamArn, _)) => streamArn->Option.getOr("")),
    streamLabel: streamInfo->Pulumi.Output.apply(((_, _, streamLabel)) => streamLabel),
    ttl: newTtl,
    pointInTimeRecovery: newPointInTimeRecovery,
  }
}

let makeTable = (
  ~attributes,
  ~globalSecondaryIndexes=?,
  ~ttl: option<int>=?,
  ~rangeKey=?,
  ~streamViewType,
  ~tags=?,
  ~opts,
  name,
) => {
  let restoreSourceName =
    Pulumi.Config.make(Some("restore"))
    ->Pulumi.Config.getObject("tables")
    ->Option.flatMap(tables => tables->Dict.get(name))

  let (dependencies, registerResource) = Util_DynamoDb_TableManager.getDependencies()

  let table = PulumiAws.DynamoDb.Table.make(
    ~name,
    ~args=Util_DynamoDb.makeTableArgs(
      ~attributes,
      ~globalSecondaryIndexes?,
      ~ttl?,
      ~rangeKey?,
      ~restoreSourceName?,
      ~streamEnabled=true,
      ~streamViewType,
      ~tags?,
    ),
    ~opts={
      ...opts,
      dependsOn: dependencies->Pulumi.Output.asInput,
    },
  )

  registerResource(table->Pulumi.Resource.makeFromJs)

  restoreSourceName->Option.isNone
  // Workaround when restore enabled
    ? updateTable(~ttl?, table)
    : table
}

let findResource = resources =>
  resources->ReventlessCore.Util.Adapter.findResource(AWS.DynamoDbStream.service)

let findResolvedResource = resources =>
  resources->ReventlessCore.Util.Adapter.findResolvedResource(AWS.DynamoDbStream.service)
