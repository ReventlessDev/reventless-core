open PulumiAws.DynamoDb.Table
open ReventlessSpec.Adapter

let toInfo: table => Pulumi.Output.t<string> = ({hashKey, rangeKey}) =>
  (hashKey, rangeKey)
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((hashKey, rangeKey)) =>
    hashKey ++ ("," ++ rangeKey->Belt.Option.getWithDefault(""))
  )

let toRuntimeTableOutput = ({name, id, arn, hashKey, rangeKey}) =>
  (name, id, arn, hashKey, rangeKey)
  ->Pulumi.Output.all5
  ->Pulumi.Output.apply(((name, id, arn, hashKey, rangeKey)) => {
    Util_DynamoDb_Runtime.id,
    name,
    arn,
    hashKey,
    rangeKey: ?rangeKey->Belt.Option.map(Js.Nullable.return),
  })

let toResource: table => resource = ({id, name, arn} as table) => {
  ReventlessSpec.Adapter.service: name->Pulumi.Output.apply(_ => AWS.DynamoDb.service),
  name,
  id,
  urn: arn,
  info: table->toInfo,
}

let arn2tableName = arn =>
  switch arn->Js.String2.split(":") {
  | [_, _, _service, _region, _account, tableName] => tableName
  | _ => Js.Exn.raiseError("Invalid ARN: " ++ arn)
  }

// Workaround when restore enabled: turn on ttl & pointInTimeRecovery again
let enableTtl: string => Js.Promise.t<ttl> = async tableName => {
  Js.log(`${__MODULE__}: enableTimeToLive for ${tableName}`)

  //open AwsSdk.DynamoDb_DynamoDb.UpdateTimeToLiveCommand
  switch await {
    tableName,
    timeToLiveSpecification: {
      enabled: true,
      attributeName: Util_DynamoDb_Runtime.purgeTimeAttributeName,
    },
  }
  ->AwsSdk.DynamoDb_DynamoDb.UpdateTimeToLiveCommand.make
  ->AwsSdk.DynamoDb_DynamoDb.UpdateTimeToLiveCommand.send {
  | res => {
      enabled: res.timeToLiveSpecification.enabled,
      attributeName: res.timeToLiveSpecification.attributeName,
    }
  }
}

let verifyTtl: (~expectedTtl: int=?, table) => Pulumi.Output.t<ttl> = (
  ~expectedTtl=?,
  {name, ttl},
) =>
  (name, ttl)
  ->Pulumi.Output.all2
  ->Pulumi.Output.flatMap(((tableName, ttl)) =>
    switch (ttl.enabled, expectedTtl) {
    | (None, Some(_))
    | (Some(false), Some(_)) =>
      enableTtl(tableName)
    | _ => ttl->Js.Promise.resolve
    }->Pulumi.Output.fromPromise
  )

let enablePointInTimeRecovery = async tableName => {
  Js.log(`${__MODULE__}: enablePointInTimeRecovery for ${tableName}`)

  open AwsSdk.DynamoDb_DynamoDb

  let updateContinuousBackups = UpdateContinuousBackupsCommand.make({
    tableName,
    pointInTimeRecoverySpecification: {pointInTimeRecoveryEnabled: true},
  })
  switch await updateContinuousBackups->UpdateContinuousBackupsCommand.send {
  | res => {enabled: res.continuousBackupsDescription.continuousBackupsStatus == #ENABLED}
  }
}

let verifyPointInTimeRecovery = (table: table) =>
  (table.name, table.pointInTimeRecovery)
  ->Pulumi.Output.all2
  ->Pulumi.Output.flatMap(((tableName, pointInTimeRecovery)) =>
    switch pointInTimeRecovery.enabled {
    | false => enablePointInTimeRecovery(tableName)
    | true => pointInTimeRecovery->Js.Promise.resolve
    }->Pulumi.Output.fromPromise
  )

let updateTable: (~ttl: int=?, table) => table = (~ttl=?, table) => {
  let newTtl = verifyTtl(~expectedTtl=?ttl, table)
  let newPointInTimeRecovery = verifyPointInTimeRecovery(table)

  {
    ...table,
    ttl: newTtl,
    pointInTimeRecovery: newPointInTimeRecovery,
  }
}

let makeTableArgs = (
  ~attributes,
  ~globalSecondaryIndexes=?,
  ~ttl: option<int>=?,
  ~rangeKey=?,
  ~restoreSourceName=?,
  ~tags=?,
  ~streamEnabled=?,
  ~streamViewType=?,
) => {
  let ttl = ttl->Belt.Option.map(_ =>
    {
      PulumiAws.DynamoDb.Table.enabled: true,
      attributeName: Util_DynamoDb_Runtime.purgeTimeAttributeName,
    }->Pulumi.Input.make
  )

  let restoreDateTime = Reventless.Env.restoreDateTime

  {
    PulumiAws.DynamoDb.Table.attributes: attributes->Pulumi.Input.make,
    hashKey: "id"->Pulumi.Input.make,
    rangeKey: ?rangeKey->Belt.Option.map(Pulumi.Input.make),
    billingMode: PAY_PER_REQUEST,
    ?globalSecondaryIndexes,
    ?tags,
    ?ttl,
    pointInTimeRecovery: {
      enabled: true,
    }->Pulumi.Input.make,
    restoreSourceName: ?restoreSourceName->Belt.Option.map(Pulumi.Input.make),
    restoreDateTime: ?restoreSourceName->Belt.Option.flatMap(_ =>
      restoreDateTime->Belt.Option.map(Pulumi.Input.make)
    ),
    restoreToLatestTime: ?restoreSourceName->Belt.Option.map(_ =>
      restoreDateTime->Belt.Option.isNone->Pulumi.Input.make
    ),
    ?streamEnabled,
    ?streamViewType,
  }
}

let option2Str = opt =>
  switch opt {
  | Some(value) => `Some(${value})`
  | None => "None"
  }

let makeTable = (
  ~attributes,
  ~globalSecondaryIndexes=?,
  ~ttl: option<int>=?,
  ~rangeKey=?,
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
    ~args=makeTableArgs(
      ~attributes,
      ~globalSecondaryIndexes?,
      ~ttl?,
      ~rangeKey?,
      ~restoreSourceName?,
      ~tags?,
    ),
    ~opts={
      ...opts,
      dependsOn: dependencies->Pulumi.Output.asInput,
    },
  )

  registerResource(table->Pulumi.Resource.makeFromJs)

  restoreSourceName->Belt.Option.isSome
  // Workaround when restore enabled
    ? updateTable(~ttl?, table)
    : table
}

let findResource = resources =>
  resources->Reventless.Util.Adapter.findResource(AWS.DynamoDb.service)

let findUnwrappedResource = resources =>
  resources->Reventless.Util.Adapter.findUnwrappedResource(AWS.DynamoDb.service)

let findResourceInOutput = resourcesOutput =>
  resourcesOutput->Reventless.Util.Adapter.findResourceInOutput(AWS.DynamoDb.service)
