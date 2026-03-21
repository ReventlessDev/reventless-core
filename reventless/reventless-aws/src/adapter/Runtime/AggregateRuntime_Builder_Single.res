module CommandTopicChannel = CommandTopicChannel.SQS_FIFO
module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

type bundledAggregateInfo = {
  specModulePath: string,
  behaviorModulePath: string,
  eventLogTableName: Pulumi.Output.t<string>,
}

let bundledAggregateInfos: dict<bundledAggregateInfo> = Dict.make()

let registerAggregate = (
  ~aggregateName,
  ~specModulePath,
  ~behaviorModulePath,
  ~eventLogTableName,
) =>
  bundledAggregateInfos->Dict.set(
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
      `forCommandTopic(bundled): commandTopic ${name} has no Aggregate parent`,
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
      `forEventCollector(bundled): eventCollector ${name} has no Aggregate parent`,
    )
  }
}

let finished = ref(false)

let finish = () =>
  if !finished.contents {
    let specs = storedSpecs->Dict.valuesToArray
    if specs->Array.length > 0 {
      let (parent, memorySize, timeout) = specs->Array.reduce((None, 0, 0), (
        (_, accMemorySize, accTimeout),
        {aggregateResource, memorySize, timeout},
      ) => {
        (
          aggregateResource.parent,
          Math.Int.max(accMemorySize, memorySize),
          Math.Int.max(accTimeout, timeout),
        )
      })
      switch parent {
      | Some(parent) =>
        let opts = {Pulumi.ComponentResource.parent: parent}

        let factoryModulePath =
          "@reventlessdev/reventless-aws/src/adapter/Runtime/AggregateHandlerFactory.mjs"

        // Build env vars and handler registrations
        let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
        let handlerRegistrations = ref([])
        let idx = ref(0)

        specs->Array.forEach(spec => {
          switch bundledAggregateInfos->Dict.get(spec.aggregateName) {
          | Some(info) =>
            let i = idx.contents
            let iStr = i->Int.toString
            let tableEnvVar = `HANDLER_${iStr}_TABLE`
            let queueUrlEnvVar = `HANDLER_${iStr}_QUEUE_URL`
            let queueArnEnvVar = `HANDLER_${iStr}_QUEUE_ARN`

            envVars->Dict.set(tableEnvVar, info.eventLogTableName->Pulumi.Output.asInput)
            envVars->Dict.set(queueUrlEnvVar, spec.queueUrl->Pulumi.Output.asInput)
            envVars->Dict.set(queueArnEnvVar, spec.queueArn->Pulumi.Output.asInput)

            let registration: Util_EntryPoint.aggregateHandlerRegistration = {
              specModulePath: info.specModulePath,
              behaviorModulePath: info.behaviorModulePath,
              eventLogTableEnvVar: tableEnvVar,
              queueUrlEnvVar,
              queueArnEnvVar,
            }
            handlerRegistrations :=
              handlerRegistrations.contents->Array.concat([registration])
            idx := i + 1
          | None =>
            Console.warn(
              `AggregateRuntime_Builder_Single: no bundled info registered for ${spec.aggregateName}`,
            )
          }
        })

        let requestContextModulePath =
          "@reventlessdev/reventless-core/src/RequestContext.res.mjs"

        let entryPointCode = Util_EntryPoint.generateAggregateEntryPoint({
          name: "AllAggregates",
          handlers: handlerRegistrations.contents,
          factoryModule: factoryModulePath,
          requestContextModule: requestContextModulePath,
        })

        let runtime = RuntimeEnvironment_Lambda.makeBundledFromEntryPoint(
          ~name="AllAggregates",
          ~entryPointCode,
          ~envVars,
          ~memorySize,
          ~timeout,
          ~opts,
        )

        // Run all connect functions (IAM policies, event source mappings)
        specs->Array.forEach(({connects}) => {
          connects->Array.forEach(connect => connect(~runtime))
        })

        // Connect EventCollector channels
        let channelSpecs =
          specs
          ->Array.map(({eventCollectorChannelSpec}) => eventCollectorChannelSpec)
          ->Array.keepSome
        let _connectResources = EventCollectorChannel.connect(
          ~name="AllAggregates",
          ~channelSpecs,
          ~runtime,
          ~opts,
        )
      | None => ()
      }
    }
    finished := true
  }
