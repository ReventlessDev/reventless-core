module CommandTopicChannel = CommandTopicChannel.SQS_Sync
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
      `forCommandTopic(per-aggregate): commandTopic ${name} has no Aggregate parent`,
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
      `forEventCollector(per-aggregate): eventCollector ${name} has no Aggregate parent`,
    )
  }
}

let finished = ref(false)

let finish = () =>
  if !finished.contents {
    // PerAggregate strategy: CommandTopic and EventCollector share one Lambda per aggregate.
    // Unlike Single (one Lambda for all) or Micro (one Lambda per function), here memorySize
    // and timeout are a single value per aggregate — the max across all registered functions.
    let specs = storedSpecs->Dict.valuesToArray
    if specs->Array.length > 0 {
      specs->Array.forEach(spec => {
        switch aggregateInfos->Dict.get(spec.aggregateName) {
        | Some(info) =>
          let aggregateOpts = {
            Pulumi.ComponentResource.parent: spec.aggregateResource,
          }
          let name =
            spec.aggregateName->ReventlessCore.ComponentType.name(
              ReventlessCore.Aggregate.componentType,
            )
          // The single per-aggregate Lambda carries the canonical `CmdHandler`
          // kind (greppable alongside Single/Micro); the EventCollector connect
          // below keeps the bare `<Entity>Aggr` stem so it composes to
          // `<Entity>AggrEventColl`.
          let lambdaName = name ++ "CmdHandler"

          // Build HANDLER_CONFIG with single handler
          let specModule =
            info.specModulePath->JSON.stringifyAny->Option.getOr(`""`)
          let behaviorModule =
            info.behaviorModulePath->JSON.stringifyAny->Option.getOr(`""`)

// `plugin` cannot be resolved inside the Lambda — LogPrefix's registry is a
          // deploy-time structure, and the Lambda-name fallback yields nothing for a
          // shared or per-aggregate command handler. Resolve it here; the shell still
          // derives `comp` itself from the spec name.
          let pluginFragment = Util_LogAttribution.pluginFragment(
            ~comp=`AggregateRuntime(${spec.aggregateName})`,
          )
          let handlerConfigOutput =
            Pulumi.Output.all3((info.eventLogTableName, spec.queueUrl, spec.queueArn))
            ->Pulumi.Output.apply(((table, queueUrl, queueArn)) =>
              `{"handlers":[{"specModule":${specModule},"behaviorModule":${behaviorModule},"eventLogTable":"${table}","queueUrl":"${queueUrl}","queueArn":"${queueArn}"${pluginFragment}}]}`
            )

          let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
          envVars->Dict.set("HANDLER_CONFIG", handlerConfigOutput->Pulumi.Output.asInput)

          // Collect user packages
          let packageDirs: dict<string> = Dict.make()
          let specPkg = Util_Bundle.extractPackageName(info.specModulePath)
          let behaviorPkg = Util_Bundle.extractPackageName(info.behaviorModulePath)
          packageDirs->Dict.set(specPkg, Util_Bundle.resolvePackageRoot(specPkg))
          packageDirs->Dict.set(behaviorPkg, Util_Bundle.resolvePackageRoot(behaviorPkg))

          // Build AssetArchive: static re-export + user packages
          let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
            ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/AggregateEntryPoint.mjs",
            ~packageDirs,
          )

          let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
            ~name=lambdaName,
            ~unitKind=ReventlessCore.Monitoring.CommandHandler,
            ~code,
            ~sourceCodeHash,
            ~envVars,
            ~memorySize=spec.memorySize,
            ~timeout=spec.timeout,
            ~opts=aggregateOpts,
          )

          spec.connects->Array.forEach(connect => connect(~runtime))

          let channelSpecs =
            spec.eventCollectorChannelSpec->Option.mapOr([], cs => [cs])
          let _connectResources = EventCollectorChannel.connect(
            ~name,
            ~channelSpecs,
            ~runtime,
            ~opts=aggregateOpts,
          )
        | None =>
          log.warn(
            ~comp="AggregateRuntime_Builder_PerAggregate",
            `no handler registered for ${spec.aggregateName}`,
          )
        }
      })
    }
    finished := true
  }
