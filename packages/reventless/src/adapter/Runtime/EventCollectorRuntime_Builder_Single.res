module Make = (
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
): (
  EventCollectorRuntime_Builder.T
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

  let grandParent = ref(None)
  let parentType = ref(None)

  let runtimeSpec = ref({
    channelSpecs: [],
    maxMemorySize: 0,
    maxTimeout: 0,
  })
  let eventCollectorHandlers = Dict.make()

  let eventCollectorHandler = parentName =>
    async (event: RuntimeEnvironment.event, context) => {
      let desc = `eventCollectorHandler for ${parentName}:`
      let _ = await event
      ->RuntimeEnvironment.groupBySource
      ->Dict.toArray
      ->Array.map(async ((urn, event)) => {
        switch eventCollectorHandlers->Dict.get(urn) {
        | Some(handlers) =>
          let count = handlers->Array.length->Int.toString
          Console.log2(`----- ${desc} found ${count} handler(s) for EventCollector`, urn)
          let _ = await handlers->Array.map(handler => handler(event, context))->Promise.all
        | None => Console.log2(`${desc} no handler found:`, urn)
        }
      })
      ->Promise.all
    }

  let validateParent = (parent: Pulumi.Resource.t) => {
    let parentName = parent.name->Option.getOr("UnnamedParent")
    parent.urn->Pulumi.Output.apply(urn => {
      let pulumiType =
        (urn->String.split("::"))[2]
        ->Option.map(fullType => {
          let parts = fullType->String.split(":")
          parts->Array.getUnsafe(parts->Array.length - 1)
        })
        ->Option.getOr("Unknown")
      Console.log(`validateParent: parent ${parentName} type: ${pulumiType}`)
      switch (grandParent.contents, parentType.contents) {
      | (None, None) =>
        parentType := Some(pulumiType)
        grandParent := parent.parent
      | (Some(grandParent), _) if Some(grandParent) != parent.parent =>
        let grandParentName = grandParent.name->Option.getOr("UnnamedGrandParent")
        JsError.throwWithMessage(
          `registerRuntimeSpec: parent ${parentName} has different parent than ${grandParentName}`,
        )
      | (_, Some(parentType)) if parentType != pulumiType =>
        JsError.throwWithMessage(
          `registerRuntimeSpec: parent ${parentName} has different type ${pulumiType} than ${parentType}`,
        )
      | _ => ()
      }
    })
  }

  let registerRuntimeSpec = (
    ~channel,
    ~eventTopics,
    ~resources,
    ~memorySize,
    ~timeout,
    parent: Pulumi.Resource.t,
  ) => {
    parent
    ->validateParent
    ->Pulumi.Output.apply(_ => {
      let {channelSpecs, maxMemorySize, maxTimeout} = runtimeSpec.contents
      runtimeSpec := {
          channelSpecs: channelSpecs->Array.concat([{channel, eventTopics, resources}]),
          maxMemorySize: Math.Int.max(maxMemorySize, memorySize),
          maxTimeout: Math.Int.max(maxTimeout, timeout),
        }
    })
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
    | Some(parentResource) =>
      let registered =
        parentResource->registerRuntimeSpec(
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
        (registered, urns, handler)
        ->Pulumi.Output.all3
        ->Pulumi.Output.apply(((_, urns, handler)) => {
          Console.log2(`***** forEventCollector ${eventCollectorName}: set handler for`, urns)
          urns->Array.map(urn => {
            let handlers = eventCollectorHandlers->Dict.get(urn)->Option.getOr([])
            eventCollectorHandlers->Dict.set(
              urn,
              handlers->Array.concat([handler->RuntimeEnvironment.asEventHandler]),
            )
          })
        })
    | None =>
      JsError.throwWithMessage(
        `forEventCollector: eventCollector ${eventCollectorName} has no parent`,
      )
    }
  }

  let finished = ref(false)

  let finish = () =>
    if !finished.contents {
      switch (grandParent.contents, parentType.contents) {
      | (Some(grandParent), Some(parentType)) =>
        let name = `All${parentType}s`
        let {channelSpecs, maxMemorySize, maxTimeout} = runtimeSpec.contents
        let runtime = RuntimeEnvironment.make(
          ~name,
          ~handler=eventCollectorHandler(name)->Pulumi.Output.make,
          ~memorySize=maxMemorySize,
          ~timeout=maxTimeout,
          ~opts={Pulumi.ComponentResource.parent: grandParent},
        )
        let opts = {Pulumi.ComponentResource.parent: grandParent}

        let _connectResources = EventCollectorChannel.connect(~name, ~channelSpecs, ~runtime, ~opts)
      | _ =>
        Console.log3(
          "EventCollectorRuntime_Builder_Single.finish: grandParent or parentType not set:",
          grandParent.contents->Option.map(grandParent =>
            `${grandParent.pulumiType} ${grandParent.name->Option.getOr("UnnamedGrandParent")}`
          ),
          parentType.contents,
        )
        JsError.throwWithMessage(
          "EventCollectorRuntime_Builder_Single.finish: grandParent or parentType not set",
        )
      }
      finished := true
    }
}
