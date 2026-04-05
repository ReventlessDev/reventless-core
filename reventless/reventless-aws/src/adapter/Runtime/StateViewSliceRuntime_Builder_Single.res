module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

type bundledStateViewSliceInfo = {
  specModulePath: string,
  queryDbTableName: Pulumi.Output.t<string>,
  queryDbResources: array<ReventlessInfra.Adapter.resource>,
}

let bundledInfos: dict<bundledStateViewSliceInfo> = Dict.make()

let registerStateViewSlice = (
  ~name,
  ~specModulePath,
  ~queryDbTableName,
  ~queryDbResources=[],
) =>
  bundledInfos->Dict.set(name, {specModulePath, queryDbTableName, queryDbResources})

type storedSpec = {
  componentName: string,
  parentResource: Pulumi.Resource.t,
  sourceUrns: Pulumi.Output.t<array<string>>,
  channelSpec: ReventlessCore.EventCollector_Adapter.channelSpec<
    EventCollectorChannel.callbackEvent,
    context,
    EventCollectorChannel.channelParts,
  >,
  memorySize: int,
  timeout: int,
}

let storedSpecs: array<storedSpec> = []
let grandParent = ref(None)

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
  let eventCollectorName = eventCollectorResource.name->Option.getOr("Unnamed")

  switch eventCollectorResource.parent {
  | Some(parentResource) =>
    let parentName = parentResource.name->Option.getOr("Unnamed")
    if grandParent.contents == None {
      grandParent := parentResource.parent
    }

    let sourceUrns =
      (eventCollector->ReventlessCore.Component.outputs).resources
      ->Array.map(({urn}) => urn)
      ->Pulumi.Output.all

    storedSpecs
    ->Array.push({
      componentName: parentName,
      parentResource,
      sourceUrns,
      channelSpec: {channel, eventTopics, resources},
      memorySize,
      timeout,
    })
    ->ignore

    Console.log(
      `StateViewSliceRuntime_Builder_Single: registered ${eventCollectorName} for ${parentName}`,
    )
  | None =>
    JsError.throwWithMessage(
      `forEventCollector(bundled): eventCollector ${eventCollectorName} has no parent`,
    )
  }
}

let finished = ref(false)

let buildLambda = (~parent, ~handlerOutputs, ~packageDirs, ~channelSpecs) => {
  let opts = {Pulumi.ComponentResource.parent: parent}
  let handlerConfigOutput =
    Pulumi.Output.all(handlerOutputs)
    ->Pulumi.Output.apply(handlers =>
      `{"handlers":[${handlers->Array.join(",")}]}`
    )

  let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
  envVars->Dict.set("HANDLER_CONFIG", handlerConfigOutput->Pulumi.Output.asInput)

  let reExportCode = `export { handler } from "@reventlessdev/reventless-aws/src/adapter/Runtime/StateViewSliceEntryPoint.mjs";`

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
    ~name="AllStateViewSlices",
    ~code,
    ~sourceCodeHash,
    ~envVars,
    ~memorySize=1024,
    ~timeout=30,
    ~opts,
  )

  let _connectResources = EventCollectorChannel.connect(
    ~name="AllStateViewSlices",
    ~channelSpecs,
    ~runtime,
    ~opts,
  )
}

let finishWithDcbEventLog = (dcbEventLog: ReventlessCore.DcbEventLog.component) =>
  if !finished.contents {
    let infoCount = bundledInfos->Dict.keysToArray->Array.length
    if infoCount > 0 {
      let dcbResource = dcbEventLog->ReventlessCore.Component.toPulumiResource
      switch dcbResource.parent {
      | Some(parent) =>
        let dcbOutputs: ReventlessCore.DcbEventLog.outputs = dcbEventLog->ReventlessCore.Component.outputs
        let eventTopics: ReventlessCore.EventTopic.allOutputs = Dict.fromArray([
          ("DcbEventLog", dcbOutputs.eventTopic),
        ])
        let channel = EventCollectorChannel.make(
          ~name="AllStateViewSlices",
          ~eventTopics,
          ~opts={Pulumi.ComponentResource.parent: parent},
        )

        let handlerOutputs: array<Pulumi.Output.t<string>> = []
        let packageDirs: dict<string> = Dict.make()
        let allQueryDbResources: array<ReventlessInfra.Adapter.resource> = []

        bundledInfos->Dict.forEachWithKey((info, _name) => {
          info.queryDbResources->Array.forEach(r => allQueryDbResources->Array.push(r)->ignore)
          let pkg = Util_Bundle.extractPackageName(info.specModulePath)
          packageDirs->Dict.set(pkg, Util_Bundle.resolvePackageRoot(pkg))

          let specModule = info.specModulePath->JSON.stringifyAny->Option.getOr(`""`)
          let etResources: array<ReventlessInfra.Adapter.resource> = dcbOutputs.eventTopic.resources
          let sourceUrn = etResources->Array.getUnsafe(0)
          let sourceUrn = sourceUrn.urn

          let handlerJson =
            Pulumi.Output.all2((info.queryDbTableName, sourceUrn))
            ->Pulumi.Output.apply(((tableName, urn)) => {
              `{"specModule":${specModule},"queryDbTableName":"${tableName}","sourceUrn":"${urn}"}`
            })
          let _ = handlerOutputs->Array.push(handlerJson)
        })

        buildLambda(
          ~parent,
          ~handlerOutputs,
          ~packageDirs,
          ~channelSpecs=[{channel: channel, eventTopics, resources: allQueryDbResources}],
        )
      | None =>
        Console.warn("StateViewSliceRuntime_Builder_Single.finishWithDcbEventLog: DCB EventLog has no parent")
      }
    }
    finished := true
  }

let finish = () =>
  if !finished.contents {
    Console.log(`StateViewSliceRuntime_Builder_Single.finish: ${storedSpecs->Array.length->Int.toString} storedSpecs, ${bundledInfos->Dict.keysToArray->Array.length->Int.toString} bundledInfos, grandParent=${grandParent.contents->Option.map(_ => "Some")->Option.getOr("None")}`)
    if storedSpecs->Array.length > 0 {
      let (maxMemorySize, maxTimeout) = storedSpecs->Array.reduce((0, 0), (
        (accMemorySize, accTimeout),
        {memorySize, timeout},
      ) => {
        (Math.Int.max(accMemorySize, memorySize), Math.Int.max(accTimeout, timeout))
      })

      switch grandParent.contents {
      | Some(parent) =>
        let opts = {Pulumi.ComponentResource.parent: parent}

        let handlerOutputs: array<Pulumi.Output.t<string>> = []
        let packageDirs: dict<string> = Dict.make()

        storedSpecs->Array.forEach(spec => {
          switch bundledInfos->Dict.get(spec.componentName) {
          | Some(info) =>
            let pkg = Util_Bundle.extractPackageName(info.specModulePath)
            packageDirs->Dict.set(pkg, Util_Bundle.resolvePackageRoot(pkg))

            let specModule =
              info.specModulePath->JSON.stringifyAny->Option.getOr(`""`)

            let handlerJson =
              Pulumi.Output.all2((info.queryDbTableName, spec.sourceUrns))
              ->Pulumi.Output.apply(((tableName, urns)) => {
                let sourceUrn = urns->Array.getUnsafe(0)
                `{"specModule":${specModule},"queryDbTableName":"${tableName}","sourceUrn":"${sourceUrn}"}`
              })
            let _ = handlerOutputs->Array.push(handlerJson)
          | None =>
            Console.warn(
              `StateViewSliceRuntime_Builder_Single: no bundled info registered for ${spec.componentName}`,
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

        let reExportCode = `export { handler } from "@reventlessdev/reventless-aws/src/adapter/Runtime/StateViewSliceEntryPoint.mjs";`

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
          ~name="AllStateViewSlices",
          ~code,
          ~sourceCodeHash,
          ~envVars,
          ~memorySize=maxMemorySize,
          ~timeout=maxTimeout,
          ~opts,
        )

        let channelSpecs = storedSpecs->Array.map(({channelSpec}) => channelSpec)
        let _connectResources = EventCollectorChannel.connect(
          ~name="AllStateViewSlices",
          ~channelSpecs,
          ~runtime,
          ~opts,
        )
      | None =>
        Console.warn(
          `StateViewSliceRuntime_Builder_Single.finish: grandParent not set`,
        )
      }
    }
    finished := true
  }
