module Make = (Channel: EventCollector_Adapter.Channel): EventCollector.T => {
  type callbackEvent = Channel.callbackEvent

  let construct = (self, name) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let name = name->ComponentType.name(EventCollector.componentType)

    let channel = Channel.make(~name, ~opts)
    self->EventCollector.setChannel(channel)

    self->Component.setOperations(
      channel.enqueueEvent->Pulumi.Output.apply(enqueueEvent => {
        EventCollector.enqueueEvent: enqueueEvent,
      }),
    )
  }

  let subscribe = (~name, ~eventTopics, ~eventCollector, ~runtime, ~opts) => {
    let name = name->ComponentType.name(EventCollector.componentType)
    let channel = eventCollector->EventCollector.channel

    let subscribeResources = channel.subscribe(~name, ~eventTopics, ~channel, ~runtime, ~opts)

    let _ = eventCollector->Component.setOutputs({
      EventCollector.name,
      resources: channel.resources->Belt.Array.concat(subscribeResources),
    })
  }

  let makeHandler = (
    ~eventCollector: EventCollector.component,
    ~eventsHandler: EventCollector.jsonEventsHandler,
  ) => {
    let channel = eventCollector->EventCollector.channel
    channel.handleChannelEvent(eventsHandler)
  }

  let make = (~name, ~opts): EventCollector.component =>
    Component.make(
      ~componentType=EventCollector.componentType->ComponentType.toString,
      ~name,
      ~construct,
      ~opts=Some(opts),
    )
}
