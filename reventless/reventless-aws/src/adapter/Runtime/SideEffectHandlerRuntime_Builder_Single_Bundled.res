module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

type bundledSideEffectInfo = {
  sideEffectModulePaths: array<string>,
}

let bundledSideEffectInfos: dict<bundledSideEffectInfo> = Dict.make()

let registerBundledSideEffectHandler = (~sideEffectHandlerName, ~sideEffectModulePaths) =>
  bundledSideEffectInfos->Dict.set(sideEffectHandlerName, {sideEffectModulePaths: sideEffectModulePaths})

type storedSpec = {
  sideEffectHandlerName: string,
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
      sideEffectHandlerName: parentName,
      parentResource,
      sourceUrns,
      channelSpec: {channel, eventTopics, resources},
      memorySize,
      timeout,
    })
    ->ignore

    Console.log(
      `SideEffectHandlerRuntime_Builder_Single_Bundled: registered ${eventCollectorName} for ${parentName}`,
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

        let factoryModulePath = Util_Bundle.resolveModule(
          "@reventlessdev/reventless-aws/src/adapter/Runtime/BundledSideEffectHandlerFactory.mjs",
        )
        let requestContextModulePath = Util_Bundle.resolveModule(
          "@reventlessdev/reventless-core/src/RequestContext.res.mjs",
        )

        let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
        let handlerRegistrations = ref([])
        let idx = ref(0)

        storedSpecs->Array.forEach(spec => {
          switch bundledSideEffectInfos->Dict.get(spec.sideEffectHandlerName) {
          | Some(info) =>
            let i = idx.contents
            let iStr = i->Int.toString
            let sourceUrnEnvVar = `HANDLER_${iStr}_SOURCE_URN`

            let _ =
              spec.sourceUrns->Pulumi.Output.apply(urns => {
                urns->Array.forEachWithIndex((urn, j) => {
                  let envVar = if j == 0 {
                    sourceUrnEnvVar
                  } else {
                    `HANDLER_${iStr}_SOURCE_URN_${j->Int.toString}`
                  }
                  envVars->Dict.set(envVar, urn->Pulumi.Input.make)
                })
              })

            let registration: Util_EntryPoint.bundledSideEffectRegistration = {
              sideEffectModulePaths: info.sideEffectModulePaths,
              sourceUrnEnvVar,
            }
            handlerRegistrations :=
              handlerRegistrations.contents->Array.concat([registration])
            idx := i + 1
          | None =>
            Console.warn(
              `SideEffectHandlerRuntime_Builder_Single_Bundled: no bundled info registered for ${spec.sideEffectHandlerName}`,
            )
          }
        })

        let entryPointCode = Util_EntryPoint.generateBundledSideEffectEntryPoint({
          name: "AllSideEffectHandlers",
          handlers: handlerRegistrations.contents,
          factoryModule: factoryModulePath,
          requestContextModule: requestContextModulePath,
        })

        let runtime = RuntimeEnvironment_Lambda.makeBundledFromEntryPoint(
          ~name="AllSideEffectHandlers",
          ~entryPointCode,
          ~envVars,
          ~memorySize=maxMemorySize,
          ~timeout=maxTimeout,
          ~opts,
        )

        let channelSpecs = storedSpecs->Array.map(({channelSpec}) => channelSpec)
        let _connectResources = EventCollectorChannel.connect(
          ~name="AllSideEffectHandlers",
          ~channelSpecs,
          ~runtime,
          ~opts,
        )
      | None =>
        Console.warn(
          "SideEffectHandlerRuntime_Builder_Single_Bundled.finish: grandParent not set",
        )
      }
    }
    finished := true
  }
