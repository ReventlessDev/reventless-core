module Make = (Channel: EventCollector_Adapter.Channel): (
  EventCollector.T with type callbackEvent = Channel.callbackEvent
) => {
  type callbackEvent = Channel.callbackEvent

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
    let opts = {Pulumi.ComponentResource.parent: eventCollectorResource}
    let channel = eventCollector->EventCollector_Adapter.channel

    let _connectResources = channel.connect(
      ~name,
      ~eventTopics,
      ~channel,
      ~runtime,
      ~resources,
      ~opts,
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
