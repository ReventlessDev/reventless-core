module CommandTopicChannel = CommandTopicChannel.SQS_FIFO
module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

type bundledAggregateInfo = {
  specModulePath: string,
  behaviorModulePath: string,
  eventLogTableName: Pulumi.Output.t<string>,
  mappingsModulePath: option<string>,
}

let bundledAggregateInfos: dict<bundledAggregateInfo> = Dict.make()

let registerAggregate = (
  ~aggregateName,
  ~specModulePath,
  ~behaviorModulePath,
  ~eventLogTableName,
  ~mappingsModulePath=?,
) =>
  bundledAggregateInfos->Dict.set(
    aggregateName,
    {specModulePath, behaviorModulePath, eventLogTableName, mappingsModulePath},
  )

type storedSpec = {
  aggregateName: string,
  aggregateResource: Pulumi.Resource.t,
  queueUrl: Pulumi.Output.t<string>,
  queueArn: Pulumi.Output.t<string>,
  commandTopicConnects: array<ReventlessCore.Runtime.connect<runtimeParts>>,
  commandGeneratorConnects: array<ReventlessCore.Runtime.connect<runtimeParts>>,
  eventCollectorChannelSpec: option<
    ReventlessCore.EventCollector_Adapter.channelSpec<
      EventCollectorChannel.callbackEvent,
      context,
      EventCollectorChannel.channelParts,
    >,
  >,
  commandTopicMemorySize: int,
  commandTopicTimeout: int,
  commandGeneratorMemorySize: int,
  commandGeneratorTimeout: int,
  eventCollectorMemorySize: int,
  eventCollectorTimeout: int,
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
    commandTopicConnects: [],
    commandGeneratorConnects: [],
    eventCollectorChannelSpec: None,
    commandTopicMemorySize: 0,
    commandTopicTimeout: 0,
    commandGeneratorMemorySize: 0,
    commandGeneratorTimeout: 0,
    eventCollectorMemorySize: 0,
    eventCollectorTimeout: 0,
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
      commandGeneratorConnects: spec.commandGeneratorConnects->Array.concat([connect]),
      commandGeneratorMemorySize: Math.Int.max(spec.commandGeneratorMemorySize, memorySize),
      commandGeneratorTimeout: Math.Int.max(spec.commandGeneratorTimeout, timeout),
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
      commandTopicConnects: spec.commandTopicConnects->Array.concat([connect]),
      commandTopicMemorySize: Math.Int.max(spec.commandTopicMemorySize, memorySize),
      commandTopicTimeout: Math.Int.max(spec.commandTopicTimeout, timeout),
    })
  | None =>
    let name = commandTopicResource.name->Option.getOr("Unnamed")
    JsError.throwWithMessage(
      `forCommandTopic(bundled-micro): commandTopic ${name} has no Aggregate parent`,
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
  ~memorySize=2048,
  ~timeout=180,
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
      eventCollectorMemorySize: Math.Int.max(spec.eventCollectorMemorySize, memorySize),
      eventCollectorTimeout: Math.Int.max(spec.eventCollectorTimeout, timeout),
    })
  | None =>
    let name = eventCollectorResource.name->Option.getOr("Unnamed")
    JsError.throwWithMessage(
      `forEventCollector(bundled-micro): eventCollector ${name} has no Aggregate parent`,
    )
  }
}

let finished = ref(false)

let finish = () =>
  if !finished.contents {
    let specs = storedSpecs->Dict.valuesToArray
    if specs->Array.length > 0 {
      let requestContextModulePath =
        "@reventlessdev/reventless-core/src/RequestContext.res.mjs"

      let commandTopicFactoryModulePath =
        "@reventlessdev/reventless-aws/src/adapter/Runtime/AggregateHandlerFactory.mjs"

      let commandGeneratorFactoryModulePath =
        "@reventlessdev/reventless-aws/src/adapter/Runtime/CommandGeneratorHandlerFactory.mjs"

      let eventMapperFactoryModulePath =
        "@reventlessdev/reventless-aws/src/adapter/Runtime/EventMapperHandlerFactory.mjs"

      specs->Array.forEach(spec => {
        switch bundledAggregateInfos->Dict.get(spec.aggregateName) {
        | Some(info) =>
          let aggregateOpts = {
            Pulumi.ComponentResource.parent: spec.aggregateResource,
          }
          let baseName =
            spec.aggregateName->ReventlessCore.ComponentType.name(
              ReventlessCore.Aggregate.componentType,
            )

          // --- CommandTopic Lambda ---
          let cmdTopicEnvVars: dict<Pulumi.Input.t<string>> = Dict.make()
          cmdTopicEnvVars->Dict.set("HANDLER_0_TABLE", info.eventLogTableName->Pulumi.Output.asInput)
          cmdTopicEnvVars->Dict.set("HANDLER_0_QUEUE_URL", spec.queueUrl->Pulumi.Output.asInput)
          cmdTopicEnvVars->Dict.set("HANDLER_0_QUEUE_ARN", spec.queueArn->Pulumi.Output.asInput)

          let cmdTopicRegistration: Util_EntryPoint.aggregateHandlerRegistration = {
            specModulePath: info.specModulePath,
            behaviorModulePath: info.behaviorModulePath,
            eventLogTableEnvVar: "HANDLER_0_TABLE",
            queueUrlEnvVar: "HANDLER_0_QUEUE_URL",
            queueArnEnvVar: "HANDLER_0_QUEUE_ARN",
          }

          let cmdTopicEntryPointCode = Util_EntryPoint.generateAggregateEntryPoint({
            name: spec.aggregateName ++ "CmdTopic",
            handlers: [cmdTopicRegistration],
            factoryModule: commandTopicFactoryModulePath,
            requestContextModule: requestContextModulePath,
          })

          let cmdTopicName = baseName ++ "CmdTopic"
          let cmdTopicRuntime = RuntimeEnvironment_Lambda.makeBundledFromEntryPoint(
            ~name=cmdTopicName,
            ~entryPointCode=cmdTopicEntryPointCode,
            ~envVars=cmdTopicEnvVars,
            ~memorySize=Math.Int.max(spec.commandTopicMemorySize, 1024),
            ~timeout=Math.Int.max(spec.commandTopicTimeout, 30),
            ~opts=aggregateOpts,
          )

          spec.commandTopicConnects->Array.forEach(connect => connect(~runtime=cmdTopicRuntime))

          // --- CommandGenerator Lambda ---
          if spec.commandGeneratorConnects->Array.length > 0 {
            let cmdGenEnvVars: dict<Pulumi.Input.t<string>> = Dict.make()
            cmdGenEnvVars->Dict.set("QUEUE_URL", spec.queueUrl->Pulumi.Output.asInput)

            let cmdGenEntryPointCode = Util_EntryPoint.generateCommandGeneratorEntryPoint({
              name: spec.aggregateName ++ "CmdGen",
              factoryModule: commandGeneratorFactoryModulePath,
              requestContextModule: requestContextModulePath,
              specModulePath: info.specModulePath,
              behaviorModulePath: info.behaviorModulePath,
              queueUrlEnvVar: "QUEUE_URL",
            })

            let cmdGenName = baseName ++ "CmdGen"
            let cmdGenRuntime = RuntimeEnvironment_Lambda.makeBundledFromEntryPoint(
              ~name=cmdGenName,
              ~entryPointCode=cmdGenEntryPointCode,
              ~envVars=cmdGenEnvVars,
              ~memorySize=Math.Int.max(spec.commandGeneratorMemorySize, 1024),
              ~timeout=Math.Int.max(spec.commandGeneratorTimeout, 30),
              ~opts=aggregateOpts,
            )

            spec.commandGeneratorConnects->Array.forEach(connect =>
              connect(~runtime=cmdGenRuntime)
            )
          }

          // --- EventMapper Lambda ---
          switch (spec.eventCollectorChannelSpec, info.mappingsModulePath) {
          | (Some(channelSpec), Some(mappingsModulePath)) =>
            let evtMapperEnvVars: dict<Pulumi.Input.t<string>> = Dict.make()
            evtMapperEnvVars->Dict.set("QUEUE_URL", spec.queueUrl->Pulumi.Output.asInput)

            let evtMapperEntryPointCode = Util_EntryPoint.generateEventMapperEntryPoint({
              name: spec.aggregateName ++ "EvtMapper",
              factoryModule: eventMapperFactoryModulePath,
              requestContextModule: requestContextModulePath,
              targetSpecModulePath: info.specModulePath,
              mappingsModulePath,
              queueUrlEnvVar: "QUEUE_URL",
            })

            let evtMapperName = baseName ++ "EvtMapper"
            let evtMapperRuntime = RuntimeEnvironment_Lambda.makeBundledFromEntryPoint(
              ~name=evtMapperName,
              ~entryPointCode=evtMapperEntryPointCode,
              ~envVars=evtMapperEnvVars,
              ~memorySize=Math.Int.max(spec.eventCollectorMemorySize, 2048),
              ~timeout=Math.Int.max(spec.eventCollectorTimeout, 180),
              ~opts=aggregateOpts,
            )

            let _connectResources = EventCollectorChannel.connect(
              ~name=evtMapperName,
              ~channelSpecs=[channelSpec],
              ~runtime=evtMapperRuntime,
              ~opts=aggregateOpts,
            )
          | (Some(_), None) =>
            Console.warn(
              `AggregateRuntime_Builder_Micro: eventCollector registered for ${spec.aggregateName} but no mappingsModulePath — skipping EventMapper Lambda`,
            )
          | _ => ()
          }
        | None =>
          Console.warn(
            `AggregateRuntime_Builder_Micro: no bundled info registered for ${spec.aggregateName}`,
          )
        }
      })
    }
    finished := true
  }
