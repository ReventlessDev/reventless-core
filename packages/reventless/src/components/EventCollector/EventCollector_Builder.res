module Make = (
  RuntimeEnvironment: Runtime.Environment,
  Channel: EventCollector_Adapter.Channel with type runtimeParts = RuntimeEnvironment.parts,
): (
  EventCollector.T
    with type callbackEvent = Channel.callbackEvent
    and type runtimeParts = RuntimeEnvironment.parts
) => {
  type callbackEvent = Channel.callbackEvent
  type runtimeParts = RuntimeEnvironment.parts

  let construct = (~eventTopics, self, name) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let name = name->ComponentType.name(EventCollector.componentType)

    let channel = Channel.make(~name, ~eventTopics, ~opts)
    self->EventCollector_Adapter.setChannel(channel)

    self->Component.setOperations(
      channel.enqueueEvent->Pulumi.Output.apply(enqueueEvent => {
        EventCollector.enqueueEvent: enqueueEvent,
      }),
    )

    self->Component.setOutputs({
      EventCollector.name,
      resources: channel.resources,
    })
  }

  let connect = (~eventTopics, ~resources, ~runtime, eventCollector) => {
    let eventCollectorResource = eventCollector->Component.toPulumiResource
    let name =
      eventCollectorResource.name
      ->Option.getOr("Unnamed")
      ->ComponentType.name(EventCollector.componentType)

    let _connectResources = Channel.connect(
      ~name,
      ~channelSpecs=[
        {channel: eventCollector->EventCollector_Adapter.channel, eventTopics, resources},
      ],
      ~runtime,
      ~opts={Pulumi.ComponentResource.parent: eventCollectorResource},
    )

    // let _ = eventCollector->Component.setOutputs({
    //   EventCollector.name,
    //   resources: channel.resources->Array.concat(connectResources),
    // })
  }

  let makeHandler = (
    ~eventCollector: EventCollector.component,
    ~eventsHandler: EventCollector.jsonEventsHandler,
  ) => {
    let channel = eventCollector->EventCollector_Adapter.channel
    channel.handleChannelEvent(eventsHandler)
  }

  let make = (~name, ~eventTopics, ~opts): EventCollector.component =>
    Component.make(
      ~componentType=EventCollector.componentType->ComponentType.toString,
      ~name,
      ~construct=construct(~eventTopics, ...),
      ~opts=Some(opts)
    )
}
