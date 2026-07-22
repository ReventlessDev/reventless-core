/**
 * Build a handler from a stream-aware, schema-decoded handler.
 * Each incoming JSON event is decoded via `schema`; decode errors become Effect failures.
 * Use this when writing handlers that want to consume a typed `Stream.t<'event>` directly.
 */
let makeStreamHandler = (
  ~eventCollector: EventCollector.component,
  ~schema: S.t<'event>,
  ~jsonEventsHandler: Stream.t<'event, string, unit> => Effect.t<unit, string, unit>,
) => {
  let jsonHandler: EventCollector.jsonEventsHandler = stream =>
    stream
    ->Stream.mapEffect(json =>
      Effect.trySync(~catch=_exn => "decode error", () => json->S.parseOrThrow(schema))
    )
    ->jsonEventsHandler

  let channel: EventCollector_Adapter.channel<_, _, _> = eventCollector->EventCollector_Adapter.channel
  channel.handleChannelEvent(jsonHandler)
}

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

  let construct = (~eventTopics, ~owner=?, self, name) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let name = name->ComponentType.name(EventCollector.componentType)

    let channel = Channel.make(~name, ~eventTopics, ~owner, ~opts)
    self->EventCollector_Adapter.setChannel(channel)

    self->Component.setOperations(
      channel.enqueueEvent->Pulumi.Output.apply(enqueueEvent => {
        let ops: EventCollector.operations = {enqueueEvent: enqueueEvent}
        ops
      }),
    )

    let outputs: EventCollector.outputs = {
      name,
      resources: channel.resources,
    }
    self->Component.setOutputs(outputs)
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
    ~jsonEventsHandler: EventCollector.jsonEventsHandler,
  ) => {
    let channel = eventCollector->EventCollector_Adapter.channel
    channel.handleChannelEvent(jsonEventsHandler)
  }

  let make = (~name, ~eventTopics, ~owner=?, ~opts): EventCollector.component =>
    Component.make(
      ~componentType=EventCollector.componentType->ComponentType.toString,
      ~name,
      ~construct=construct(~eventTopics, ~owner?, ...),
      ~opts=Some(opts),
    )
}
