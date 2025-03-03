module Make = (Channel: EventCollector_Adapter.Channel): EventCollector.T => {
  type callbackEvent = Channel.callbackEvent
  type channel<'context> = EventCollector.channel<callbackEvent, 'context>

  @set
  external setChannel: (EventCollector.component, channel<'context>) => unit = "channel"
  @get
  external channel: EventCollector.component => channel<'context> = "channel"

  let construct = (self, name) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let name = name->ComponentType.name(EventCollector.componentType)

    let channel = Channel.make(~name, ~opts)
    self->setChannel(channel)

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

  let subscribe = (~name, ~eventTopics, ~channel: channel<'context>, ~runtime, ~opts): array<
    ReventlessSpec.Adapter.resource,
  > => {
    let name = name->ComponentType.name(EventCollector.componentType)
    channel.subscribe(~name, ~eventTopics, ~channel, ~runtime, ~opts)
  }

  let makeHandler = (
    ~channel: channel<'context>,
    ~eventsHandler: EventCollector.jsonEventsHandler,
  ) => {
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
