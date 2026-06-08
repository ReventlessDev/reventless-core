module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

let log = ReventlessCore.Logger.fromEnv()

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

type sliceInfo = {
  specModulePath: string,
  projectionModulePath: string,
  queryDbTableName: Pulumi.Output.t<string>,
  queryDbResources: array<ReventlessInfra.Adapter.resource>,
}

let sliceInfos: dict<sliceInfo> = Dict.make()

let registerStateViewSlice = (
  ~name,
  ~specModulePath,
  ~projectionModulePath,
  ~queryDbTableName,
  ~queryDbResources=[],
) =>
  sliceInfos->Dict.set(
    name,
    {specModulePath, projectionModulePath, queryDbTableName, queryDbResources},
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

    log.info(
      ~comp="StateViewSliceRuntime_Builder_Single",
      `registered ${eventCollectorName} for ${parentName}`,
    )
  | None =>
    JsError.throwWithMessage(
      `forEventCollector(single): eventCollector ${eventCollectorName} has no parent`,
    )
  }
}

let finished = ref(false)

let buildLambda = (~parent, ~handlerOutputs, ~packageDirs, ~channelSpecs, ~memorySize=1024, ~timeout=30) => {
  let opts = {Pulumi.ComponentResource.parent: parent}
  let handlerConfigOutput =
    Pulumi.Output.all(handlerOutputs)
    ->Pulumi.Output.apply(handlers =>
      `{"handlers":[${handlers->Array.join(",")}]}`
    )

  let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
  envVars->Dict.set("HANDLER_CONFIG", handlerConfigOutput->Pulumi.Output.asInput)

  // Bundle the framework packages alongside the entry point so the deployed
  // Lambda picks up local edits without waiting for a Lambda Layer rebuild
  // (the layer fetches @reventlessdev/reventless-* from GitHub Packages, not
  // the local pnpm workspace). Mirrors the DCB asset pattern in
  // PluginRuntime_Builder.forDcbCommandTopic. Util_Bundle co-bundles `effect`
  // automatically when reventless-aws is present.
  packageDirs->Dict.set(
    "@reventlessdev/reventless-aws",
    Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-aws"),
  )
  packageDirs->Dict.set(
    "@reventlessdev/reventless-core",
    Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-core"),
  )

  let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
    ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/StateViewSliceEntryPoint.mjs",
    ~packageDirs,
  )

  let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
    ~name="AllStateViewSlices",
    ~code,
    ~sourceCodeHash,
    ~envVars,
    ~memorySize,
    ~timeout,
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
    let infoCount = sliceInfos->Dict.keysToArray->Array.length
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

        sliceInfos->Dict.forEachWithKey((info, _name) => {
          info.queryDbResources->Array.forEach(r => allQueryDbResources->Array.push(r)->ignore)
          let specPkg = Util_Bundle.extractPackageName(info.specModulePath)
          packageDirs->Dict.set(specPkg, Util_Bundle.resolvePackageRoot(specPkg))
          let projectionPkg = Util_Bundle.extractPackageName(info.projectionModulePath)
          packageDirs->Dict.set(projectionPkg, Util_Bundle.resolvePackageRoot(projectionPkg))

          let specModule = info.specModulePath->JSON.stringifyAny->Option.getOr(`""`)
          let projectionModule =
            info.projectionModulePath->JSON.stringifyAny->Option.getOr(`""`)
          let etResources: array<ReventlessInfra.Adapter.resource> = dcbOutputs.eventTopic.resources
          let sourceUrn = etResources->Array.getUnsafe(0)
          let sourceUrn = sourceUrn.urn

          let handlerJson =
            Pulumi.Output.all2((info.queryDbTableName, sourceUrn))
            ->Pulumi.Output.apply(((tableName, urn)) => {
              `{"specModule":${specModule},"projectionModule":${projectionModule},"queryDbTableName":"${tableName}","sourceUrn":"${urn}"}`
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
        log.warn(
          ~comp="StateViewSliceRuntime_Builder_Single",
          "finishWithDcbEventLog: DCB EventLog has no parent",
        )
      }
    }
    finished := true
  }

let finish = () =>
  if !finished.contents {
    log.info(
      ~comp="StateViewSliceRuntime_Builder_Single",
      `finish: ${storedSpecs->Array.length->Int.toString} storedSpecs, ${sliceInfos->Dict.keysToArray->Array.length->Int.toString} sliceInfos, grandParent=${grandParent.contents->Option.map(_ => "Some")->Option.getOr("None")}`,
    )
    if storedSpecs->Array.length > 0 {
      let (maxMemorySize, maxTimeout) = storedSpecs->Array.reduce((0, 0), (
        (accMemorySize, accTimeout),
        {memorySize, timeout},
      ) => {
        (Math.Int.max(accMemorySize, memorySize), Math.Int.max(accTimeout, timeout))
      })

      switch grandParent.contents {
      | Some(parent) =>
        let handlerOutputs: array<Pulumi.Output.t<string>> = []
        let packageDirs: dict<string> = Dict.make()

        storedSpecs->Array.forEach(spec => {
          switch sliceInfos->Dict.get(spec.componentName) {
          | Some(info) =>
            let specPkg = Util_Bundle.extractPackageName(info.specModulePath)
            packageDirs->Dict.set(specPkg, Util_Bundle.resolvePackageRoot(specPkg))
            let projectionPkg = Util_Bundle.extractPackageName(info.projectionModulePath)
            packageDirs->Dict.set(projectionPkg, Util_Bundle.resolvePackageRoot(projectionPkg))

            let specModule =
              info.specModulePath->JSON.stringifyAny->Option.getOr(`""`)
            let projectionModule =
              info.projectionModulePath->JSON.stringifyAny->Option.getOr(`""`)

            let handlerJson =
              Pulumi.Output.all2((info.queryDbTableName, spec.sourceUrns))
              ->Pulumi.Output.apply(((tableName, urns)) => {
                let sourceUrn = urns->Array.getUnsafe(0)
                `{"specModule":${specModule},"projectionModule":${projectionModule},"queryDbTableName":"${tableName}","sourceUrn":"${sourceUrn}"}`
              })
            let _ = handlerOutputs->Array.push(handlerJson)
          | None =>
            log.warn(
              ~comp="StateViewSliceRuntime_Builder_Single",
              `no handler registered for ${spec.componentName}`,
            )
          }
        })

        buildLambda(
          ~parent,
          ~handlerOutputs,
          ~packageDirs,
          ~channelSpecs=storedSpecs->Array.map(({channelSpec}) => channelSpec),
          ~memorySize=maxMemorySize,
          ~timeout=maxTimeout,
        )
      | None =>
        log.warn(~comp="StateViewSliceRuntime_Builder_Single", `finish: grandParent not set`)
      }
    }
    finished := true
  }
