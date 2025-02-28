module Make = (Channel: EventCollector_Adapter.Channel): EventCollector.T => {
  type callbackEvent = Channel.callbackEvent
  type channel<'context> = EventCollector.channel<callbackEvent, 'context>

  let construct = (self, name, ~eventTopics, ~channel: channel<'context>, ~runtime) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let name = name->ComponentType.name(EventCollector.componentType)

    let subscribeResources = channel.subscribe(~name, ~eventTopics, ~channel, ~runtime, ~opts)

    self->Component.setOperations(
      channel.enqueueEvent->Pulumi.Output.apply(enqueueEvent => {
        EventCollector.enqueueEvent: enqueueEvent,
      }),
    )

    self->Component.setOutputs({
      EventCollector.name,
      resources: channel.resources->Belt.Array.concat(subscribeResources),
    })
  }

  let makeChannel = (~name, ~opts): channel<'context> => {
    let name = name->ComponentType.name(EventCollector.componentType)
    Channel.make(~name, ~opts)
  }

  let makeHandler = (
    ~channel: channel<'context>,
    ~eventsHandler: EventCollector.jsonEventsHandler,
  ) => {
    channel.handleChannelEvent(eventsHandler)
  }

  let make = (~name, ~eventTopics, ~channel, ~runtime, ~opts): EventCollector.component =>
    Component.make(
      ~componentType=EventCollector.componentType->ComponentType.toString,
      ~name,
      ~construct=construct(~eventTopics, ~channel, ~runtime, ...),
      ~opts
    )
}
