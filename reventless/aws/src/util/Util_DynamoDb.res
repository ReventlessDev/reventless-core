open PulumiAws.DynamoDb.Table
@@warning("-44")
open ReventlessInfra.Adapter

let log = ReventlessCore.Logger.fromEnv()

let toResourceInfo: table => Pulumi.Output.t<ReventlessInfra.Adapter.resourceInfo> = ({hashKey, rangeKey}) =>
  (hashKey, rangeKey)
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((hashKey, rangeKey)) => ReventlessInfra.Adapter.StorageKeys({partitionKey: hashKey, sortKey: rangeKey}))

let toResolvedTableOutput = ({name, id, arn, hashKey, rangeKey}) =>
  (name, id, arn, hashKey, rangeKey)
  ->Pulumi.Output.all5
  ->Pulumi.Output.apply(((name, id, arn, hashKey, rangeKey)) => {
    Util_DynamoDb_Runtime.id,
    name,
    arn,
    hashKey,
    rangeKey: ?(rangeKey->Option.map(rangeKey => rangeKey->Nullable.make)),
  })

let toResource = (~tags=?, {id, name, arn} as table) =>
  make(
    ~name,
    ~id,
    ~urn=arn,
    ~service=name->Pulumi.Output.apply(_ => AWS.DynamoDb.service),
    ~resourceInfo=table->toResourceInfo,
    ~resourceType="aws:dynamodb:Table"->Pulumi.Output.make,
    ~tags=?tags,
  )


let arn2tableName = arn =>
  switch arn->String.split(":") {
  | [_, _, _service, _region, _account, tableName] => tableName
  | _ => JsError.throwWithMessage("Invalid ARN: " ++ arn)
  }

// Workaround when restore enabled: turn on ttl & pointInTimeRecovery again
let enableTtl: string => promise<ttl> = async tableName => {
  log.info(~comp="DynamoDb", `enableTimeToLive for ${tableName}`)

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
  ->Pulumi.Output.flatMap(((tableName, ttl)) => {
    // Pulumi resolves table.ttl to undefined when no TTL is configured on the table.
    // Cast to Nullable to safely handle this at the JS boundary.
    let ttlOpt: option<ttl> = (ttl->Obj.magic: Nullable.t<ttl>)->Nullable.toOption
    switch (ttlOpt->Option.flatMap(t => t.enabled), expectedTtl) {
    | (None, Some(_))
    | (Some(false), Some(_)) =>
      enableTtl(tableName)
    | _ => ttlOpt->Option.getOr({attributeName: ""})->Promise.resolve
    }->Pulumi.Output.fromPromise
  })

let enablePointInTimeRecovery = async tableName => {
  log.info(~comp="DynamoDb", `enablePointInTimeRecovery for ${tableName}`)

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
    | true => pointInTimeRecovery->Promise.resolve
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
  let ttl = ttl->Option.map(_ =>
    {
      PulumiAws.DynamoDb.Table.enabled: true,
      attributeName: Util_DynamoDb_Runtime.purgeTimeAttributeName,
    }->Pulumi.Input.make
  )

  let restoreDateTime = ReventlessCore.Env.restoreDateTime

  {
    PulumiAws.DynamoDb.Table.attributes: attributes->Pulumi.Input.make,
    hashKey: "id"->Pulumi.Input.make,
    rangeKey: ?(rangeKey->Option.map(Pulumi.Input.make)),
    billingMode: PAY_PER_REQUEST,
    ?globalSecondaryIndexes,
    ?tags,
    ?ttl,
    pointInTimeRecovery: {
      enabled: true,
    }->Pulumi.Input.make,
    restoreSourceName: ?(restoreSourceName->Option.map(Pulumi.Input.make)),
    restoreDateTime: ?(
      restoreSourceName->Option.flatMap(_ => restoreDateTime->Option.map(Pulumi.Input.make))
    ),
    restoreToLatestTime: ?(
      restoreSourceName->Option.map(_ => restoreDateTime->Option.isNone->Pulumi.Input.make)
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
    ->Option.flatMap(tables => tables->Dict.get(name))

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

  restoreSourceName->Option.isNone
  // Workaround when restore enabled
    ? updateTable(~ttl?, table)
    : table
}

let findResource = resources =>
  resources->ReventlessCore.Util.Adapter.findResource(AWS.DynamoDb.service)

let findResolvedResource = resources =>
  resources->ReventlessCore.Util.Adapter.findResolvedResource(AWS.DynamoDb.service)

let findResourceInOutput = resourcesOutput =>
  resourcesOutput->ReventlessCore.Util.Adapter.findResourceInOutput(AWS.DynamoDb.service)
