module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

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

module type Config = {
  type info
  type registration

  let name: string
  let builderName: string
  let factoryModulePath: string
  let infos: dict<info>

  let processHandler: (
    ~envVars: dict<Pulumi.Input.t<string>>,
    ~info: info,
    ~indexStr: string,
    ~sourceUrnEnvVar: string,
  ) => registration

  let generateEntryPoint: (
    string,
    array<registration>,
    string,
    string,
  ) => string
}

module Make = (C: Config) => {
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
        `${C.builderName}: registered ${eventCollectorName} for ${parentName}`,
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

          let factoryModulePath = C.factoryModulePath
          let requestContextModulePath =
            "@reventlessdev/reventless-core/src/RequestContext.res.mjs"

          let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
          let handlerRegistrations = ref([])
          let idx = ref(0)

          storedSpecs->Array.forEach(spec => {
            switch C.infos->Dict.get(spec.componentName) {
            | Some(info) =>
              let i = idx.contents
              let iStr = i->Int.toString
              let sourceUrnEnvVar = `HANDLER_${iStr}_SOURCE_URN`

              // Set the primary source URN env var synchronously with an
              // Output-wrapped value. Setting inside Output.apply is a race
              // condition — the dict entry may not exist when the Lambda
              // resource is created.
              envVars->Dict.set(
                sourceUrnEnvVar,
                spec.sourceUrns
                ->Pulumi.Output.apply(urns => urns->Array.getUnsafe(0))
                ->Pulumi.Output.asInput,
              )

              // Set additional source URN env vars for multi-source ReadModels.
              let _ =
                spec.sourceUrns->Pulumi.Output.apply(urns => {
                  urns->Array.forEachWithIndex((urn, j) => {
                    if j > 0 {
                      let envVar = `HANDLER_${iStr}_SOURCE_URN_${j->Int.toString}`
                      envVars->Dict.set(envVar, urn->Pulumi.Input.make)
                    }
                  })
                })

              let registration = C.processHandler(
                ~envVars,
                ~info,
                ~indexStr=iStr,
                ~sourceUrnEnvVar,
              )
              handlerRegistrations :=
                handlerRegistrations.contents->Array.concat([registration])
              idx := i + 1
            | None =>
              Console.warn(
                `${C.builderName}: no bundled info registered for ${spec.componentName}`,
              )
            }
          })

          let entryPointCode = C.generateEntryPoint(
            C.name,
            handlerRegistrations.contents,
            factoryModulePath,
            requestContextModulePath,
          )

          let runtime = RuntimeEnvironment_Lambda.makeBundledFromEntryPoint(
            ~name=C.name,
            ~entryPointCode,
            ~envVars,
            ~memorySize=maxMemorySize,
            ~timeout=maxTimeout,
            ~opts,
          )

          let channelSpecs = storedSpecs->Array.map(({channelSpec}) => channelSpec)
          let _connectResources = EventCollectorChannel.connect(
            ~name=C.name,
            ~channelSpecs,
            ~runtime,
            ~opts,
          )
        | None =>
          Console.warn(
            `${C.builderName}.finish: grandParent not set`,
          )
        }
      }
      finished := true
    }
}
