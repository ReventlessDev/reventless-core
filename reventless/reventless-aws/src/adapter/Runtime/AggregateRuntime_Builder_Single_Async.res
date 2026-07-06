// Async variant of AggregateRuntime_Builder_Single.
// Uses SQS_Async (FIFO) instead of SQS_Sync — commands return CommandPending immediately.
// Use via Platform.Aggregate.MakeAsync for high-contention aggregates where the caller
// cannot wait for synchronous processing.
module CommandTopicChannel = CommandTopicChannel.SQS_Async
module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

let log = ReventlessCore.Logger.fromEnv()

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

type aggregateInfo = {
  specModulePath: string,
  behaviorModulePath: string,
  eventLogTableName: Pulumi.Output.t<string>,
}

let aggregateInfos: dict<aggregateInfo> = Dict.make()

// Per-flavor commandHandlerConfig override; populated by Platform.MakeWithConfig
// from the user-supplied `commandHandlerConfig.aggregates.async` record.
let configRef: ref<ReventlessCore.Runtime.commandHandlerConfig> = ref(
  ({}: ReventlessCore.Runtime.commandHandlerConfig),
)
let setConfig = (c: ReventlessCore.Runtime.commandHandlerConfig) => configRef := c

let registerAggregate = (
  ~aggregateName,
  ~specModulePath,
  ~behaviorModulePath,
  ~eventLogTableName,
) =>
  aggregateInfos->Dict.set(
    aggregateName,
    {specModulePath, behaviorModulePath, eventLogTableName},
  )

type storedSpec = {
  aggregateName: string,
  aggregateResource: Pulumi.Resource.t,
  queueUrl: Pulumi.Output.t<string>,
  queueArn: Pulumi.Output.t<string>,
  connects: array<ReventlessCore.Runtime.connect<runtimeParts>>,
  eventCollectorChannelSpec: option<
    ReventlessCore.EventCollector_Adapter.channelSpec<
      EventCollectorChannel.callbackEvent,
      context,
      EventCollectorChannel.channelParts,
    >,
  >,
  memorySize: int,
  timeout: int,
}

let storedSpecs: dict<storedSpec> = Dict.make()

let getStoredSpec = (aggregateName, aggregateResource) =>
  storedSpecs
  ->Dict.get(aggregateName)
  ->Option.getOr({
    aggregateName,
    aggregateResource,
    queueUrl: ""->Pulumi.Output.make,
    queueArn: ""->Pulumi.Output.make,
    connects: [],
    eventCollectorChannelSpec: None,
    memorySize: 0,
    timeout: 0,
  })

let forCommandGenerator: ReventlessCore.Runtime.forComponent<
  ReventlessCore.CommandGenerator.effectEventHandler<context>,
  runtimeParts,
  ReventlessCore.CommandGenerator.component,
> = (
  ~handler as _,
  ~connect,
  ~memorySize=1024,
  ~timeout=30,
  commandGenerator,
) => {
  let resource = commandGenerator->ReventlessCore.Component.toPulumiResource
  switch resource.parent {
  | Some(aggregateResource) =>
    let aggregateName = aggregateResource.name->Option.getOr("Unnamed")
    let spec = getStoredSpec(aggregateName, aggregateResource)
    storedSpecs->Dict.set(aggregateName, {
      ...spec,
      connects: spec.connects->Array.concat([connect]),
      memorySize: Math.Int.max(spec.memorySize, memorySize),
      timeout: Math.Int.max(spec.timeout, timeout),
    })
  | None => ()
  }
}

let forCommandTopic: ReventlessCore.Runtime.forComponent<
  ReventlessCore.Runtime.effectHandler<
    CommandTopicChannel.callbackEvent,
    context,
    unit,
    string,
  >,
  runtimeParts,
  ReventlessCore.CommandTopic.component<'op>,
> = (
  ~handler as _,
  ~connect,
  ~memorySize=1024,
  ~timeout=30,
  commandTopic,
) => {
  let commandTopicResource = commandTopic->ReventlessCore.Component.toPulumiResource
  switch commandTopicResource.parent {
  | Some(aggregateResource) =>
    let aggregateName = aggregateResource.name->Option.getOr("Unnamed")
    // Extract the SQS queue from the channel parts
    let channel = commandTopic->ReventlessCore.CommandTopic_Adapter.channel
    let channelParts: Util.SQS.channelParts = Obj.magic(channel.parts)
    let queue = channelParts.queue

    let spec = getStoredSpec(aggregateName, aggregateResource)
    storedSpecs->Dict.set(aggregateName, {
      ...spec,
      queueUrl: queue.id,
      queueArn: queue.arn,
      connects: spec.connects->Array.concat([connect]),
      memorySize: Math.Int.max(spec.memorySize, memorySize),
      timeout: Math.Int.max(spec.timeout, timeout),
    })
  | None =>
    let name = commandTopicResource.name->Option.getOr("Unnamed")
    JsError.throwWithMessage(
      `forCommandTopic(single-async): commandTopic ${name} has no Aggregate parent`,
    )
  }
}

let forEventCollector: ReventlessCore.Runtime.forEventCollector<
  ReventlessCore.Runtime.effectHandler<
    EventCollectorChannel.callbackEvent,
    context,
    unit,
    string,
  >,
  ReventlessCore.EventCollector.component,
> = (
  ~handler as _,
  ~eventTopics,
  ~resources,
  ~memorySize=1024,
  ~timeout=30,
  eventCollector,
) => {
  let eventCollectorResource = eventCollector->ReventlessCore.Component.toPulumiResource
  let channel = eventCollector->ReventlessCore.EventCollector_Adapter.channel
  switch eventCollectorResource.parent->Option.flatMap(parent => parent.parent) {
  | Some(aggregateResource) =>
    let aggregateName = aggregateResource.name->Option.getOr("Unnamed")
    let spec = getStoredSpec(aggregateName, aggregateResource)
    storedSpecs->Dict.set(aggregateName, {
      ...spec,
      eventCollectorChannelSpec: Some({channel, eventTopics, resources}),
      memorySize: Math.Int.max(spec.memorySize, memorySize),
      timeout: Math.Int.max(spec.timeout, timeout),
    })
  | None =>
    let name = eventCollectorResource.name->Option.getOr("Unnamed")
    JsError.throwWithMessage(
      `forEventCollector(single-async): eventCollector ${name} has no Aggregate parent`,
    )
  }
}

let finished = ref(false)

let finish = () =>
  if !finished.contents {
    let specs = storedSpecs->Dict.valuesToArray
    if specs->Array.length > 0 {
      // See AggregateRuntime_Builder_Single.finish for the rationale behind
      // dropping the max-of-zeros reduce in favor of `configRef`.
      let parent = specs->Array.reduce(None, (_, {aggregateResource}) => aggregateResource.parent)
      let cfg = configRef.contents
      switch parent {
      | Some(parent) =>
        let opts = {Pulumi.ComponentResource.parent: parent}

        // Build HANDLER_CONFIG as a single JSON env var.
        // Each handler's dynamic values (table name, queue URL/ARN) are Pulumi Outputs
        // that resolve at deploy time. Static values (module paths) are plain strings.
        let handlerOutputs: array<Pulumi.Output.t<string>> = []
        let packageDirs: dict<string> = Dict.make()

        // Classic Postgres backend: add a `pgConnection` object to every handler
        // entry so the AggregateEntryPoint Postgres branch activates (absent →
        // DynamoDB path, unchanged). Whole-Lambda toggle — all aggregates follow
        // the platform selection, matching EventLogStorage.Selectable.
        let pgSelection = EventLogBackend.get()
        let pgConnectionFragment = switch pgSelection {
        | Some(sel) =>
          sel.connectionConfig->Pulumi.Output.apply(cc =>
            `,"pgConnection":${cc->PgConnection.connectionConfigToJson->JSON.stringify}`
          )
        | None => Pulumi.Output.make("")
        }

        specs->Array.forEach(spec => {
          switch aggregateInfos->Dict.get(spec.aggregateName) {
          | Some(info) =>
            let specPkg = Util_Bundle.extractPackageName(info.specModulePath)
            let behaviorPkg = Util_Bundle.extractPackageName(info.behaviorModulePath)
            packageDirs->Dict.set(specPkg, Util_Bundle.resolvePackageRoot(specPkg))
            packageDirs->Dict.set(behaviorPkg, Util_Bundle.resolvePackageRoot(behaviorPkg))

            let specModule =
              info.specModulePath->JSON.stringifyAny->Option.getOr(`""`)
            let behaviorModule =
              info.behaviorModulePath->JSON.stringifyAny->Option.getOr(`""`)

            let handlerJson =
              Pulumi.Output.all4((
                info.eventLogTableName,
                spec.queueUrl,
                spec.queueArn,
                pgConnectionFragment,
              ))
              ->Pulumi.Output.apply(((table, queueUrl, queueArn, pgFragment)) =>
                `{"specModule":${specModule},"behaviorModule":${behaviorModule},"eventLogTable":"${table}","queueUrl":"${queueUrl}","queueArn":"${queueArn}"${pgFragment}}`
              )
            let _ = handlerOutputs->Array.push(handlerJson)
          | None =>
            log.warn(
              ~comp="AggregateRuntime_Builder_Single_Async",
              `no handler registered for ${spec.aggregateName}`,
            )
          }
        })

        let handlerConfigOutput =
          Pulumi.Output.all(handlerOutputs)
          ->Pulumi.Output.apply(handlers =>
            `{"handlers":[${handlers->Array.join(",")}]}`
          )

        let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
        envVars->Dict.set("HANDLER_CONFIG", handlerConfigOutput->Pulumi.Output.asInput)
        // Flip AggregateEntryPoint into async mode — Route 1 (AppSync direct
        // invoke) becomes fire-and-forget → SQS, returning CommandPending.
        // The sync (default) builder leaves this unset.
        envVars->Dict.set("DISPATCH_MODE", "async"->Pulumi.Input.make)
        cfg.envVars->Option.forEach(extra =>
          extra->Dict.forEachWithKey((value, key) => {
            if envVars->Dict.get(key)->Option.isNone {
              envVars->Dict.set(key, value->Pulumi.Output.make->Pulumi.Output.asInput)
            }
          })
        )

        // Build AssetArchive: static re-export + user packages
        let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
          ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/AggregateEntryPoint.mjs",
          ~packageDirs,
        )

        cfg.sqsBatchSize->Option.forEach(CommandTopicChannel.setBatchSize)

        // Postgres-backed classic EventLog → the command Lambda talks to RDS, so it
        // must land in-VPC on the DB-access security group + private subnets.
        // makeFromCodeAsset adds the EC2-ENI IAM automatically when vpcConfig is
        // present (C1).
        let vpcConfig = switch pgSelection {
        | Some(sel) =>
          Some(
            sel.securityGroupId
            ->Pulumi.Output.apply(sgId =>
              (
                {
                  PulumiAws.Lambda.Function.subnetIds: sel.subnetIds->Pulumi.Input.make,
                  securityGroupIds: [sgId->Pulumi.Input.make]->Pulumi.Input.make,
                }: PulumiAws.Lambda.Function.vpcConfig
              )
            )
            ->Pulumi.Output.asInput,
          )
        | None => None
        }

        let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
          ~name="AllAggregatesAsyncCmdHandler",
          ~code,
          ~sourceCodeHash,
          ~envVars,
          ~memorySize=?cfg.memorySize,
          ~timeout=?cfg.timeout,
          ~reservedConcurrency=?cfg.reservedConcurrency,
          ~ephemeralStorageMb=?cfg.ephemeralStorageMb,
          ~logRetentionDays=?cfg.logRetentionDays,
          ~vpcConfig=?vpcConfig,
          ~opts,
        )

        // Grant the Postgres-backed command Lambda read access to the RDS-managed
        // master secret so PgRuntime can resolve the DB password at cold start.
        switch pgSelection {
        | Some(sel) =>
          let _ = sel.connectionConfig->Pulumi.Output.apply(cc => {
            open PulumiAws.PolicyDocument
            PulumiAws.IAM.RolePolicy.make(
              ~name="AllAggregatesAsyncCmdHandler-pgSecret",
              ~args={
                policy: PulumiAws.PolicyDocument.make(
                  ~id="AllAggregatesAsyncCmdHandler-pgSecretPolicy",
                  ~statements=[
                    {
                      sid: "AllowGetPgSecret",
                      effect: Allow,
                      actions: Action("secretsmanager:GetSecretValue"),
                      resources: Resource(cc.secretArn),
                    },
                  ],
                )
                ->PulumiAws.PolicyDocument.toJsonString
                ->Pulumi.Input.make,
                role: runtime.parts.lambdaRole.id->Pulumi.Output.asInput,
              },
            )
          })
        | None => ()
        }

        specs->Array.forEach(({connects}) => {
          connects->Array.forEach(connect => connect(~runtime))
        })

        CommandTopicChannel.clearBatchSize()

        let channelSpecs =
          specs
          ->Array.map(({eventCollectorChannelSpec}) => eventCollectorChannelSpec)
          ->Array.keepSome
        let _connectResources = EventCollectorChannel.connect(
          ~name="AllAggregatesAsync",
          ~channelSpecs,
          ~runtime,
          ~opts,
        )
      | None => ()
      }
    }
    finished := true
  }
