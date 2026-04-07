module CommandTopicChannel = CommandTopicChannel.SQS_FIFO
module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

type aggregateInfo = {
  specModulePath: string,
  behaviorModulePath: string,
  eventLogTableName: Pulumi.Output.t<string>,
  mappingsModulePath: option<string>,
}

let aggregateInfos: dict<aggregateInfo> = Dict.make()

let registerAggregate = (
  ~aggregateName,
  ~specModulePath,
  ~behaviorModulePath,
  ~eventLogTableName,
  ~mappingsModulePath=?,
) =>
  aggregateInfos->Dict.set(
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
      `forCommandTopic(micro): commandTopic ${name} has no Aggregate parent`,
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
      `forEventCollector(micro): eventCollector ${name} has no Aggregate parent`,
    )
  }
}

let finished = ref(false)

let finish = () =>
  if !finished.contents {
    let specs = storedSpecs->Dict.valuesToArray
    if specs->Array.length > 0 {
      specs->Array.forEach(spec => {
        switch aggregateInfos->Dict.get(spec.aggregateName) {
        | Some(info) =>
          let aggregateOpts = {
            Pulumi.ComponentResource.parent: spec.aggregateResource,
          }
          let baseName =
            spec.aggregateName->ReventlessCore.ComponentType.name(
              ReventlessCore.Aggregate.componentType,
            )

          // Collect user packages (shared by CmdTopic and CmdGen)
          let packageDirs: dict<string> = Dict.make()
          let specPkg = Util_Bundle.extractPackageName(info.specModulePath)
          let behaviorPkg = Util_Bundle.extractPackageName(info.behaviorModulePath)
          packageDirs->Dict.set(specPkg, Util_Bundle.resolvePackageRoot(specPkg))
          packageDirs->Dict.set(behaviorPkg, Util_Bundle.resolvePackageRoot(behaviorPkg))

          let specModule =
            info.specModulePath->JSON.stringifyAny->Option.getOr(`""`)
          let behaviorModule =
            info.behaviorModulePath->JSON.stringifyAny->Option.getOr(`""`)

          let reExportCode = `export { handler } from "@reventlessdev/reventless-aws/src/adapter/Runtime/AggregateEntryPoint.mjs";`

          // --- CommandTopic Lambda ---
          let cmdTopicHandlerConfigOutput =
            Pulumi.Output.all3((info.eventLogTableName, spec.queueUrl, spec.queueArn))
            ->Pulumi.Output.apply(((table, queueUrl, queueArn)) =>
              `{"handlers":[{"specModule":${specModule},"behaviorModule":${behaviorModule},"eventLogTable":"${table}","queueUrl":"${queueUrl}","queueArn":"${queueArn}"}]}`
            )

          let cmdTopicEnvVars: dict<Pulumi.Input.t<string>> = Dict.make()
          cmdTopicEnvVars->Dict.set("HANDLER_CONFIG", cmdTopicHandlerConfigOutput->Pulumi.Output.asInput)

          let cmdTopicArchiveContents: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
          cmdTopicArchiveContents->Dict.set(
            "index.mjs",
            Pulumi.Asset.stringAsset(reExportCode)->Pulumi.Archive.assetToAssetOrArchive,
          )
          packageDirs->Dict.forEachWithKey((pkgRoot, pkgName) => {
            cmdTopicArchiveContents->Dict.set(
              `node_modules/${pkgName}`,
              Util_Bundle.createFilteredPackageArchive(pkgRoot)
              ->Pulumi.Archive.archiveToAssetOrArchive,
            )
          })

          let cmdTopicCode = Pulumi.Archive.assetArchive(cmdTopicArchiveContents)
          let cmdTopicSourceCodeHash = Util_Bundle.hashString(
            reExportCode ++ packageDirs->Dict.keysToArray->Array.join(","),
          )

          let cmdTopicName = baseName ++ "CmdTopic"
          let cmdTopicRuntime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
            ~name=cmdTopicName,
            ~code=cmdTopicCode,
            ~sourceCodeHash=cmdTopicSourceCodeHash,
            ~envVars=cmdTopicEnvVars,
            ~memorySize=Math.Int.max(spec.commandTopicMemorySize, 1024),
            ~timeout=Math.Int.max(spec.commandTopicTimeout, 30),
            ~opts=aggregateOpts,
          )

          spec.commandTopicConnects->Array.forEach(connect => connect(~runtime=cmdTopicRuntime))

          // --- CommandGenerator Lambda ---
          if spec.commandGeneratorConnects->Array.length > 0 {
            let cmdGenHandlerConfigOutput =
              Pulumi.Output.all3((info.eventLogTableName, spec.queueUrl, spec.queueArn))
              ->Pulumi.Output.apply(((table, queueUrl, queueArn)) =>
                `{"handlers":[{"specModule":${specModule},"behaviorModule":${behaviorModule},"eventLogTable":"${table}","queueUrl":"${queueUrl}","queueArn":"${queueArn}"}]}`
              )

            let cmdGenEnvVars: dict<Pulumi.Input.t<string>> = Dict.make()
            cmdGenEnvVars->Dict.set("HANDLER_CONFIG", cmdGenHandlerConfigOutput->Pulumi.Output.asInput)

            let cmdGenArchiveContents: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
            cmdGenArchiveContents->Dict.set(
              "index.mjs",
              Pulumi.Asset.stringAsset(reExportCode)->Pulumi.Archive.assetToAssetOrArchive,
            )
            packageDirs->Dict.forEachWithKey((pkgRoot, pkgName) => {
              cmdGenArchiveContents->Dict.set(
                `node_modules/${pkgName}`,
                Util_Bundle.createFilteredPackageArchive(pkgRoot)
                ->Pulumi.Archive.archiveToAssetOrArchive,
              )
            })

            let cmdGenCode = Pulumi.Archive.assetArchive(cmdGenArchiveContents)
            let cmdGenSourceCodeHash = Util_Bundle.hashString(
              reExportCode ++ packageDirs->Dict.keysToArray->Array.join(","),
            )

            let cmdGenName = baseName ++ "CmdGen"
            let cmdGenRuntime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
              ~name=cmdGenName,
              ~code=cmdGenCode,
              ~sourceCodeHash=cmdGenSourceCodeHash,
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

            let targetSpecModule =
              info.specModulePath->JSON.stringifyAny->Option.getOr(`""`)
            let mappingsModuleJson =
              mappingsModulePath->JSON.stringifyAny->Option.getOr(`""`)

            let handlerConfigJson =
              spec.queueUrl
              ->Pulumi.Output.apply(queueUrl =>
                `{"targetSpecModule":${targetSpecModule},"mappingsModule":${mappingsModuleJson},"queueUrl":"${queueUrl}"}`
              )
            evtMapperEnvVars->Dict.set("HANDLER_CONFIG", handlerConfigJson->Pulumi.Output.asInput)

            let evtMapperPackageDirs: dict<string> = Dict.make()
            let specPkg = Util_Bundle.extractPackageName(info.specModulePath)
            let mappingsPkg = Util_Bundle.extractPackageName(mappingsModulePath)
            evtMapperPackageDirs->Dict.set(specPkg, Util_Bundle.resolvePackageRoot(specPkg))
            evtMapperPackageDirs->Dict.set(mappingsPkg, Util_Bundle.resolvePackageRoot(mappingsPkg))

            let evtMapperReExportCode = `export { handler } from "@reventlessdev/reventless-aws/src/adapter/Runtime/EventMapperEntryPoint.mjs";`

            let evtMapperArchiveContents: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
            evtMapperArchiveContents->Dict.set(
              "index.mjs",
              Pulumi.Asset.stringAsset(evtMapperReExportCode)->Pulumi.Archive.assetToAssetOrArchive,
            )
            evtMapperPackageDirs->Dict.forEachWithKey((pkgRoot, pkgName) => {
              evtMapperArchiveContents->Dict.set(
                `node_modules/${pkgName}`,
                Util_Bundle.createFilteredPackageArchive(pkgRoot)
                ->Pulumi.Archive.archiveToAssetOrArchive,
              )
            })

            let evtMapperCode = Pulumi.Archive.assetArchive(evtMapperArchiveContents)
            let evtMapperSourceCodeHash = Util_Bundle.hashString(
              evtMapperReExportCode ++ evtMapperPackageDirs->Dict.keysToArray->Array.join(","),
            )

            let evtMapperName = baseName ++ "EvtMapper"
            let evtMapperRuntime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
              ~name=evtMapperName,
              ~code=evtMapperCode,
              ~sourceCodeHash=evtMapperSourceCodeHash,
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
            `AggregateRuntime_Builder_Micro: no handler registered for ${spec.aggregateName}`,
          )
        }
      })
    }
    finished := true
  }
