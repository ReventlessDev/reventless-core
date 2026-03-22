module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

type bundledReadModelInfo = {
  specModulePath: string,
  mappingsModulePath: string,
  queryDbTableName: Pulumi.Output.t<string>,
}

let bundledReadModelInfos: dict<bundledReadModelInfo> = Dict.make()

let registerReadModel = (
  ~readModelName,
  ~specModulePath,
  ~mappingsModulePath,
  ~queryDbTableName,
) =>
  bundledReadModelInfos->Dict.set(
    readModelName,
    {specModulePath, mappingsModulePath, queryDbTableName},
  )

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
      `EventCollectorRuntime_Builder_Single: registered ${eventCollectorName} for ${parentName}`,
    )
  | None =>
    JsError.throwWithMessage(
      `forEventCollector(bundled): eventCollector ${eventCollectorName} has no parent`,
    )
  }
}

let finished = ref(false)

let finish = () =>
  if !finished.contents {
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
          switch bundledReadModelInfos->Dict.get(spec.componentName) {
          | Some(info) =>
            // Collect unique user packages for the code asset
            let specPkg = Util_Bundle.extractPackageName(info.specModulePath)
            let mappingsPkg = Util_Bundle.extractPackageName(info.mappingsModulePath)
            packageDirs->Dict.set(specPkg, Util_Bundle.resolvePackageRoot(specPkg))
            packageDirs->Dict.set(mappingsPkg, Util_Bundle.resolvePackageRoot(mappingsPkg))

            let specModule =
              info.specModulePath->JSON.stringifyAny->Option.getOr(`""`)
            let mappingsModule =
              info.mappingsModulePath->JSON.stringifyAny->Option.getOr(`""`)

            let handlerJson =
              Pulumi.Output.all2((info.queryDbTableName, spec.sourceUrns))
              ->Pulumi.Output.apply(((tableName, urns)) => {
                let sourceUrn = urns->Array.getUnsafe(0)
                `{"specModule":${specModule},"mappingsModule":${mappingsModule},"queryDbTableName":"${tableName}","sourceUrn":"${sourceUrn}"}`
              })
            let _ = handlerOutputs->Array.push(handlerJson)
          | None =>
            Console.warn(
              `EventCollectorRuntime_Builder_Single: no bundled info registered for ${spec.componentName}`,
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

        let reExportCode = `export { handler } from "@reventlessdev/reventless-aws/src/adapter/Runtime/ReadModelEntryPoint.res.mjs";`

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
          ~name="AllReadModels",
          ~code,
          ~sourceCodeHash,
          ~envVars,
          ~memorySize=maxMemorySize,
          ~timeout=maxTimeout,
          ~opts,
        )

        let channelSpecs = storedSpecs->Array.map(({channelSpec}) => channelSpec)
        let _connectResources = EventCollectorChannel.connect(
          ~name="AllReadModels",
          ~channelSpecs,
          ~runtime,
          ~opts,
        )
      | None =>
        Console.warn(
          `EventCollectorRuntime_Builder_Single.finish: grandParent not set`,
        )
      }
    }
    finished := true
  }
