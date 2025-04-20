module Make = (
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
): (
  ReadModelRuntime_Builder.T
    with type context = RuntimeEnvironment.context
    and type runtimeParts = RuntimeEnvironment.parts
    and module EventCollectorChannel = EventCollectorChannel
) => {
  type context = RuntimeEnvironment.context
  type runtimeParts = RuntimeEnvironment.parts
  module EventCollectorChannel = EventCollectorChannel

  type runtimeSpec = {
    channelSpecs: array<
      EventCollector_Adapter.channelSpec<
        EventCollectorChannel.callbackEvent,
        context,
        EventCollectorChannel.channelParts,
      >,
    >,
    maxMemorySize: int,
    maxTimeout: int,
  }

  let plugin = ref(None)
  let runtimeSpec = ref({
    channelSpecs: [],
    maxMemorySize: 0,
    maxTimeout: 0,
  })
  let eventCollectorHandlers = Js.Dict.empty()

  let readModelHandler = readModelName => async (event: RuntimeEnvironment.event, context) => {
    let desc = `readModelHandler for ${readModelName}:`
    let _ =
      await event
      ->RuntimeEnvironment.groupBySource
      ->Dict.toArray
      ->Array.map(async ((urn, event)) => {
        switch eventCollectorHandlers->Js.Dict.get(urn) {
        | Some(handlers) =>
          let count = handlers->Array.length->Int.toString
          Js.log2(`----- ${desc} found ${count} handler(s) for EventCollector`, urn)
          let _ = await handlers->Array.map(handler => handler(event, context))->Promise.all
        | None => Js.log2(`${desc} no handler found:`, urn)
        }
      })
      ->Promise.all
  }

  let registerRuntimeSpec = (
    ~channel,
    ~eventTopics,
    ~resources,
    ~memorySize,
    ~timeout,
    readModel: Pulumi.Resource.t,
  ) => {
    let readModelName = readModel.name->Option.getOr("UnnamedReadModel")
    switch plugin.contents {
    | None => plugin := readModel.parent
    | Some(plugin) =>
      let pluginName = plugin.name->Option.getOr("UnnamedPlugin")
      if Some(plugin) != readModel.parent {
        Js.Exn.raiseError(
          `registerRuntimeSpec: readModel ${readModelName} has different parent than plugin ${pluginName}`,
        )
      }
    }
    let {channelSpecs, maxMemorySize, maxTimeout} = runtimeSpec.contents
    runtimeSpec := {
        channelSpecs: channelSpecs->Array.concat([{channel, eventTopics, resources}]),
        maxMemorySize: Math.Int.max(maxMemorySize, memorySize),
        maxTimeout: Math.Int.max(maxTimeout, timeout),
      }
  }

  let forEventCollector = (
    ~handler: Pulumi.Output.t<
      Runtime.eventHandler<EventCollectorChannel.callbackEvent, context, unit>,
    >,
    ~eventTopics: EventTopic.allOutputs,
    ~resources: array<ReventlessSpec.Adapter.resource>,
    ~memorySize=1024,
    ~timeout=30,
    eventCollector: EventCollector.component,
  ) => {
    let eventCollectorResource = eventCollector->Component.toPulumiResource
    let eventCollectorName = eventCollectorResource.name->Option.getOr("Unnamed")
    let channel = eventCollector->EventCollector_Adapter.channel
    switch eventCollectorResource.parent {
    | Some(readModelResource) =>
      readModelResource->registerRuntimeSpec(
        ~channel,
        ~eventTopics,
        ~resources,
        ~memorySize,
        ~timeout,
      )
      let urns =
        (eventCollector->Component.outputs).resources
        ->Array.map(({urn}) => urn)
        ->Pulumi.Output.all
      let _ =
        (urns, handler)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((urns, handler)) => {
          Js.log2(`***** forEventCollector ${eventCollectorName}: set handler for`, urns)
          urns->Array.map(urn => {
            let handlers = eventCollectorHandlers->Dict.get(urn)->Option.getOr([])
            eventCollectorHandlers->Dict.set(
              urn,
              handlers->Array.concat([handler->RuntimeEnvironment.asEventHandler]),
            )
          })
        })
    | None =>
      Js.Exn.raiseError(
        `forEventCollector: eventCollector ${eventCollectorName} has no ReadModel parent`,
      )
    }
  }

  let finished = ref(false)

  let finish = () =>
    if !finished.contents {
      switch plugin.contents {
      | Some(plugin) =>
        let {channelSpecs, maxMemorySize, maxTimeout} = runtimeSpec.contents
        let runtime = RuntimeEnvironment.make(
          ~name="AllReadModels",
          ~handler=readModelHandler("AllReadModels")->Pulumi.Output.make,
          ~memorySize=maxMemorySize,
          ~timeout=maxTimeout,
          ~opts={Pulumi.ComponentResource.parent: plugin},
        )
        let opts = {Pulumi.ComponentResource.parent: plugin}

        let _connectResources = EventCollectorChannel.connect(
          ~name="AllReadModels",
          ~channelSpecs,
          ~runtime,
          ~opts,
        )
      | None => ()
      }
      finished := true
    }
}
