let make: ReventlessCore.Counter_Adapter.handlerMaker = (
  ~name,
  ~referencesName,
  ~referencesDb,
  ~countsName,
  ~countsDb,
  ~counterHandler as _,
  ~specModulePath,
  ~mappingsModulePath,
  ~publishChannelId,
  ~opts,
) => {
  let referencesDbResource = referencesDb.resources->Util.DynamoDbStream.findResource
  let referencesStream = referencesDbResource->Util.DynamoDbStream.toStreamResource
  let countsDbResource = countsDb.resources->Util.DynamoDbStream.findResource
  let countsStream = countsDbResource->Util.DynamoDbStream.toStreamResource

  let envVars: dict<Pulumi.Input.t<string>> = Dict.make()

  let countsTableName = (countsDb.resources->Array.getUnsafe(0)).name

  let targetSpecModule =
    specModulePath->JSON.stringifyAny->Option.getOr(`""`)
  let mappingsModule =
    mappingsModulePath->JSON.stringifyAny->Option.getOr(`""`)

  let handlerConfigJson =
    Pulumi.Output.all3((countsTableName, publishChannelId, referencesStream.urn))
    ->Pulumi.Output.apply(((table, queueUrl, refArn)) => {
      let countsArn = "" // Will be set separately
      `{"targetSpecModule":${targetSpecModule},"mappingsModule":${mappingsModule},"countsTableName":"${table}","publishChannelId":"${queueUrl}","referencesStreamArn":"${refArn}","countsStreamArn":"${countsArn}"}`
    })

  // countsStreamArn is in a separate Output — merge into config
  let fullHandlerConfigJson =
    Pulumi.Output.all2((handlerConfigJson, countsStream.urn))
    ->Pulumi.Output.apply(((config, countsArn)) =>
      config->String.replace(`"countsStreamArn":""`, `"countsStreamArn":"${countsArn}"`)
    )

  envVars->Dict.set("HANDLER_CONFIG", fullHandlerConfigJson->Pulumi.Output.asInput)

  // Build code asset
  let packageDirs: dict<string> = Dict.make()
  let specPkg = Util_Bundle.extractPackageName(specModulePath)
  let mappingsPkg = Util_Bundle.extractPackageName(mappingsModulePath)
  packageDirs->Dict.set(specPkg, Util_Bundle.resolvePackageRoot(specPkg))
  packageDirs->Dict.set(mappingsPkg, Util_Bundle.resolvePackageRoot(mappingsPkg))

  let reExportCode = `export { handler } from "@reventlessdev/reventless-aws/src/adapter/Runtime/CounterEntryPoint.mjs";`

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

  let componentOpts: Pulumi.ComponentResource.options = {parent: ?opts.parent}

  let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
    ~name,
    ~code,
    ~sourceCodeHash,
    ~envVars,
    ~memorySize=1024,
    ~timeout=30,
    ~opts=componentOpts,
  )

  let lambda = runtime.parts.lambda

  let subscribe = (sourceName, source) =>
    Util_EventSourceMapping.subscribe(
      ~lambda=lambda,
      ~targetName=name,
      ~sourceName,
      ~source,
      ~opts,
    )

  let _ = subscribe(referencesName, referencesStream)
  let _ = subscribe(countsName, countsStream)

  {
    ReventlessCore.Counter_Adapter.addToCounterTarget: counterTarget =>
      CounterHandler_DynamoDbStream_Runtime.addToCounterTarget(countsDbResource, counterTarget),
  }
}
