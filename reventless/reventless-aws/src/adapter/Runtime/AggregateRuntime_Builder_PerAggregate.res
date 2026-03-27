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
      specs->Array.forEach(spec => {
        switch bundledAggregateInfos->Dict.get(spec.aggregateName) {
        | Some(info) =>
          let aggregateOpts = {
            Pulumi.ComponentResource.parent: spec.aggregateResource,
          }
          let name =
            spec.aggregateName->ReventlessCore.ComponentType.name(
              ReventlessCore.Aggregate.componentType,
            )

          // Build HANDLER_CONFIG with single handler
          let specModule =
            info.specModulePath->JSON.stringifyAny->Option.getOr(`""`)
          let behaviorModule =
            info.behaviorModulePath->JSON.stringifyAny->Option.getOr(`""`)

          let handlerConfigOutput =
            Pulumi.Output.all3((info.eventLogTableName, spec.queueUrl, spec.queueArn))
            ->Pulumi.Output.apply(((table, queueUrl, queueArn)) =>
              `{"handlers":[{"specModule":${specModule},"behaviorModule":${behaviorModule},"eventLogTable":"${table}","queueUrl":"${queueUrl}","queueArn":"${queueArn}"}]}`
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
          let reExportCode = `export { handler } from "@reventlessdev/reventless-aws/src/adapter/Runtime/AggregateEntryPoint.mjs";`

          let archiveContents: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
          archiveContents->Dict.set(
            "index.mjs",
            Pulumi.Asset.stringAsset(reExportCode)->Pulumi.Archive.assetToAssetOrArchive,
          )
          packageDirs->Dict.forEachWithKey((pkgRoot, pkgName) => {
            archiveContents->Dict.set(
              `node_modules/${pkgName}`,
              Util_Bundle.createFilteredPackageArchive(pkgRoot)
              ->Pulumi.Archive.archiveToAssetOrArchive,
            )
          })

          let code = Pulumi.Archive.assetArchive(archiveContents)
          let sourceCodeHash = Util_Bundle.hashString(
            reExportCode ++ packageDirs->Dict.keysToArray->Array.join(","),
          )

          let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
            ~name,
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
          Console.warn(
            `AggregateRuntime_Builder_PerAggregate: no bundled info registered for ${spec.aggregateName}`,
          )
        }
      })
    }
    finished := true
  }
