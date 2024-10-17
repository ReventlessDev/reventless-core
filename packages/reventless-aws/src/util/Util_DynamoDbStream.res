let toInfo = (table: PulumiAws.DynamoDb.Table.t) =>
  (table["hashKey"], table["rangeKey"], table["streamArn"])
  ->Pulumi.Output.all3
  ->Pulumi.Output.apply(((hashKey, rangeKey, streamArn)) =>
    hashKey ++ ("," ++ (rangeKey->Belt.Option.getWithDefault("") ++ ("," ++ streamArn)))
  )

let streamArnFromDynamoDbTableResource = table =>
  (table["info"], table["name"])
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((tableInfo, tableName)) =>
    switch tableInfo->Js.String2.split(",") {
    | parts if parts->Belt.Array.length < 3 || parts[2]->Js.String2.trim == "" =>
      Js.Exn.raiseError("No streamArn field given for table " ++ tableName)
    | parts => parts[2]
    }
  )

let toResource = (table: PulumiAws.DynamoDb.Table.t) =>
  Reventless.Adapter.resource(
    ~service=table["name"]->Pulumi.Output.apply(_ => Util_DynamoDbStream_Runtime.service),
    ~name=table["name"],
    ~id=table["id"],
    ~urn=table["arn"],
    ~info=table->toInfo,
  )

let toStreamResource = (table: ReventlessSpec.Adapter.resource) => {
  let streamArn = table->streamArnFromDynamoDbTableResource

  Reventless.Adapter.resource(
    ~service=table["name"]->Pulumi.Output.apply(_ => Util_DynamoDbStream_Runtime.service),
    ~name=table["name"],
    ~id=streamArn,
    ~urn=streamArn,
    ~info=table["name"]->Pulumi.Output.apply(_ => ""),
  )
}

// Workaround when restore enabled: turn on stream, ttl & pointInTimeRecovery again
open AwsSdk.DynamoDb_DynamoDb

let enableStream = async tableName => {
  Js.log(`${__MODULE__}: enableStream for ${tableName}`)

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

let verifyStream = table =>
  (table["name"], table["streamEnabled"], table["streamArn"], table["streamLabel"])
  ->Pulumi.Output.all4
  ->Pulumi.Output.flatMap(((tableName, streamEnabled, streamArn, streamLabel)) =>
    switch streamEnabled {
    | None
    | Some(false) =>
      enableStream(tableName)
    | Some(true) => (true, Some(streamArn), streamLabel)->Js.Promise.resolve
    }->Pulumi.Output.fromPromise
  )

let updateTable: (~ttl: int=?, PulumiAws.DynamoDb.Table.table) => PulumiAws.DynamoDb.Table.table = (
  ~ttl=?,
  table,
) => {
  let streamInfo = verifyStream(table)

  let newTtl = Util_DynamoDb.verifyTtl(~expectedTtl=?ttl, table)
  let newPointInTimeRecovery = Util_DynamoDb.verifyPointInTimeRecovery(table)

  table->Js.Obj.assign({
    "streamEnabled": streamInfo->Pulumi.Output.apply(((enabled, _, _)) => enabled),
    "streamArn": streamInfo->Pulumi.Output.apply(((_, streamArn, _)) =>
      streamArn->Belt.Option.getWithDefault("")
    ),
    "streamLabel": streamInfo->Pulumi.Output.apply(((_, _, streamLabel)) => streamLabel),
    "ttl": newTtl,
    "pointInTimeRecovery": newPointInTimeRecovery,
  })
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
    ->Belt.Option.flatMap(tables => tables->Js.Dict.get(name))

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
      (),
    ),
    ~opts=opts->Js.Obj.assign({
      "dependsOn": dependencies->Pulumi.Output.asInput,
    }),
    (),
  )

  ()

  registerResource(. table->Pulumi.Resource.makeFromJs)

  restoreSourceName->Belt.Option.isSome
  // Workaround when restore enabled
    ? updateTable(~ttl?, table)
    : table
}

let findResource = resources =>
  resources->Reventless.Util.Adapter.findResource(Util_DynamoDbStream_Runtime.service)

let findUnwrappedResource = resources =>
  resources->Reventless.Util.Adapter.findUnwrappedResource(Util_DynamoDbStream_Runtime.service)
