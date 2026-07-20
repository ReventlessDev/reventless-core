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

  let log = Logger.fromEnv()
  let grandParent = ref(None)
  let parentType = ref(None)

  let runtimeSpec = ref({
    channelSpecs: [],
    maxMemorySize: 0,
    maxTimeout: 0,
  })
  type effectHandler = Runtime.effectHandler<RuntimeEnvironment.event, context, unit, string>
  let eventCollectorHandlers: dict<array<effectHandler>> = Dict.make()

  let eventCollectorHandler = parentName =>
    async (event: RuntimeEnvironment.event, context) => {
      let correlationId = event->RuntimeEnvironment.extractCorrelationId
      let causationId = event->RuntimeEnvironment.extractCausationId
      let comp = `EventCollectorRuntime(${parentName})`
      // Shared dispatch helper annotates correlationId / comp / causationId so the
      // application handler's own log lines carry them (see Runtime.runEffect).
      let runEffect = effect => Runtime.runEffect(~correlationId?, ~causationId?, ~comp, effect)
      let _ = await event
      ->RuntimeEnvironment.groupBySource
      ->Dict.toArray
      ->Array.map(async ((urn, event)) => {
        switch eventCollectorHandlers->Dict.get(urn) {
        | Some(handlers) =>
          let count = handlers->Array.length->Int.toString
          EffectLogger.logDebug(
            ~comp,
            `found ${count} handler(s) for ${urn}`,
          )->Effect.runSync
          let _ = await handlers
          ->Array.map(handler => runEffect(handler(event, context)))
          ->Promise.all
        | None => EffectLogger.logWarn(~comp, `no handler found: ${urn}`)->Effect.runSync
        }
      })
      ->Promise.all
    }

  let validateParent = (parent: Pulumi.Resource.t) => {
    let parentName = parent.name->Option.getOr("UnnamedParent")
    // Set grandParent synchronously so finish() can create resources
    // during the same build phase. Type validation defers to Output.apply.
    if grandParent.contents == None {
      grandParent := parent.parent
    }
    parent.urn->Pulumi.Output.apply(urn => {
      let pulumiType =
        (urn->String.split("::"))[2]
        ->Option.map(fullType => {
          let parts = fullType->String.split(":")
          parts->Array.getUnsafe(parts->Array.length - 1)
        })
        ->Option.getOr("Unknown")
      log.debug(~comp="EventCollectorRuntime", `validateParent: parent ${parentName} type: ${pulumiType}`)
      switch (parentType.contents) {
      | None =>
        parentType := Some(pulumiType)
      | Some(existingType) if existingType != pulumiType =>
        JsError.throwWithMessage(
          `registerRuntimeSpec: parent ${parentName} has different type ${pulumiType} than ${existingType}`,
        )
      | _ => ()
      }
      switch grandParent.contents {
      | Some(grandParent) if Some(grandParent) != parent.parent =>
        let grandParentName = grandParent.name->Option.getOr("UnnamedGrandParent")
        JsError.throwWithMessage(
          `registerRuntimeSpec: parent ${parentName} has different parent than ${grandParentName}`,
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
      Runtime.effectHandler<EventCollectorChannel.callbackEvent, context, unit, string>,
    >,
    ~eventTopics: EventTopic.allOutputs,
    ~resources: array<ReventlessInfra.Adapter.resource>,
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
          log.debug(
            ~comp="EventCollectorRuntime",
            `forEventCollector ${eventCollectorName}: set handler for ${urns->Array.join(", ")}`,
          )
          urns->Array.map(urn => {
            let handlers = eventCollectorHandlers->Dict.get(urn)->Option.getOr([])
            eventCollectorHandlers->Dict.set(
              urn,
              handlers->Array.concat([handler->RuntimeEnvironment.asEffectHandler]),
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
      switch grandParent.contents {
      | Some(grandParent) =>
        let name = `All${parentType.contents->Option.getOr("EventCollector")}s`
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
        // grandParent/parentType not set — either no handlers were registered
        // (e.g. all StateViewSlices went through Bundled path) or Pulumi outputs
        // haven't resolved yet. Skip silently.
        ()
      }
      finished := true
    }
}
