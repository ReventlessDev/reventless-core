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

      let factoryModulePath =
        "@reventlessdev/reventless-aws/src/adapter/Runtime/ReadModelHandlerFactory.mjs"
      let requestContextModulePath =
        "@reventlessdev/reventless-core/src/RequestContext.res.mjs"

      let name = eventCollectorResource.name->ReventlessCore.ComponentType.nameOpt(
        ReventlessCore.EventCollector.componentType,
      )
      let opts = {Pulumi.ComponentResource.parent: eventCollectorResource}

      let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
      envVars->Dict.set("HANDLER_0_TABLE", info.queryDbTableName->Pulumi.Output.asInput)

      let _ = sourceUrns->Pulumi.Output.apply(urns => {
        urns->Array.forEachWithIndex((urn, j) => {
          let envVar = if j == 0 {
            "HANDLER_0_SOURCE_URN"
          } else {
            `HANDLER_0_SOURCE_URN_${j->Int.toString}`
          }
          envVars->Dict.set(envVar, urn->Pulumi.Input.make)
        })
      })

      let registration: Util_EntryPoint.readModelRegistration = {
        specModulePath: info.specModulePath,
        mappingsModulePath: info.mappingsModulePath,
        queryDbTableEnvVar: "HANDLER_0_TABLE",
        sourceUrnEnvVar: "HANDLER_0_SOURCE_URN",
      }

      let entryPointCode = Util_EntryPoint.generateReadModelEntryPoint({
        name: parentName,
        handlers: [registration],
        factoryModule: factoryModulePath,
        requestContextModule: requestContextModulePath,
      })

      let runtime = RuntimeEnvironment_Lambda.makeBundledFromEntryPoint(
        ~name,
        ~entryPointCode,
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
