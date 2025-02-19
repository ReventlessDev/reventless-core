module Make = (Channel: EventCollector_Adapter.Channel): EventCollector.T => {
  let construct = (
    ~eventTopics,
    ~eventsHandler,
    ~memorySize,
    ~timeout,
    ~policy1,
    ~policy2,
    self,
    name,
  ) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let channel = Channel.make(
      ~name=name->ComponentType.name(EventCollector.componentType),
      ~eventTopics,
      ~memorySize,
      ~timeout,
      ~policy1,
      ~policy2,
      ~handleEvents=eventsHandler,
      ~opts,
    )

    self->Component.setOperations(
      channel.enqueueEvent->Pulumi.Output.apply(enqueueEvent => {
        EventCollector.enqueueEvent: enqueueEvent,
      }),
    )

    self->Component.setOutputs({EventCollector.name, resources: channel.resources})
  }

  let make = (
    ~name,
    ~eventTopics,
    ~eventsHandler,
    ~memorySize=512,
    ~timeout=120,
    ~policy1,
    ~policy2,
    ~opts,
  ): EventCollector.component =>
    Component.make(
      ~componentType=EventCollector.componentType->ComponentType.toString,
      ~name,
      ~construct=construct(
        ~eventTopics,
        ~eventsHandler,
        ~memorySize,
        ~timeout,
        ~policy1,
        ~policy2,
        ...
      ),
      ~opts,
    )
}
