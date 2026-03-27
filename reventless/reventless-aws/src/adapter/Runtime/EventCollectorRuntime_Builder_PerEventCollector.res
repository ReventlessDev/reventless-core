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

    switch bundledReadModelInfos->Dict.get(parentName) {
    | Some(info) =>
      let sourceUrns =
        (eventCollector->ReventlessCore.Component.outputs).resources
        ->Array.map(({urn}) => urn)
        ->Pulumi.Output.all

      let name = eventCollectorResource.name->ReventlessCore.ComponentType.nameOpt(
        ReventlessCore.EventCollector.componentType,
      )
      let opts = {Pulumi.ComponentResource.parent: eventCollectorResource}

      // Build HANDLER_CONFIG with single handler
      let specModule =
        info.specModulePath->JSON.stringifyAny->Option.getOr(`""`)
      let mappingsModule =
        info.mappingsModulePath->JSON.stringifyAny->Option.getOr(`""`)

      let handlerConfigOutput =
        Pulumi.Output.all2((info.queryDbTableName, sourceUrns))
        ->Pulumi.Output.apply(((tableName, urns)) => {
          let sourceUrn = urns->Array.getUnsafe(0)
          `{"handlers":[{"specModule":${specModule},"mappingsModule":${mappingsModule},"queryDbTableName":"${tableName}","sourceUrn":"${sourceUrn}"}]}`
        })

      let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
      envVars->Dict.set("HANDLER_CONFIG", handlerConfigOutput->Pulumi.Output.asInput)

      // Collect user packages
      let packageDirs: dict<string> = Dict.make()
      let specPkg = Util_Bundle.extractPackageName(info.specModulePath)
      let mappingsPkg = Util_Bundle.extractPackageName(info.mappingsModulePath)
      packageDirs->Dict.set(specPkg, Util_Bundle.resolvePackageRoot(specPkg))
      packageDirs->Dict.set(mappingsPkg, Util_Bundle.resolvePackageRoot(mappingsPkg))

      // Build AssetArchive: static re-export + user packages
      let reExportCode = `export { handler } from "@reventlessdev/reventless-aws/src/adapter/Runtime/ReadModelEntryPoint.mjs";`

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
        ~memorySize,
        ~timeout,
        ~opts,
      )

      let _connectResources = EventCollectorChannel.connect(
        ~name,
        ~channelSpecs=[{channel, eventTopics, resources}],
        ~runtime,
        ~opts,
      )
    | None =>
      Console.warn(
        `EventCollectorRuntime_Builder_PerEventCollector: no bundled info registered for ${parentName}`,
      )
    }
  | None =>
    JsError.throwWithMessage(
      `forEventCollector(bundled): eventCollector ${eventCollectorName} has no parent`,
    )
  }
}

let finish = () => ()
