module Make = (
  Target: ReventlessSpec.EventMapping.Target,
  SpecificEventCollector: EventCollector.T,
  Mappings: EventMapper.Mappings with module Target := Target,
  AggregateRuntimeBuilder: AggregateRuntime_Builder.T
    with type EventCollectorChannel.callbackEvent := SpecificEventCollector.callbackEvent,
): EventMapper.T => {
  module Target = Target

  let construct = (
    ~allEventTopics,
    ~queryEngine,
    ~publishJsons,
    ~resources,
    ~memorySize,
    ~timeout,
    self,
    name,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let name = name->ComponentType.name(EventMapper.componentType)

    module CounterHandler = EventMapper_Callback.MakeCounterHandler(
      Target,
      Mappings,
      {
        let publishJsons = publishJsons
        let queryEngine = queryEngine
      },
    )

    let (counterOperations, counterOutputs) = Mappings.counter->Option.mapOr(
      (
        Pulumi.Output.make({
          let ops: Counter.operations = {
            count: async _items => Console.log("No counter deployed, but trying to use count"),
            addToCounterTarget: async _target =>
              Console.log("No counter deployed, but trying to use addToCounterTarget"),
          }
          ops
        }),
        None,
      ),
      (module(Counter: Counter.T)) => {
        let counter = Counter.make(
          ~name,
          ~counterEventsHandler=CounterHandler.handleCounterEvents,
          ~opts,
        )
        let counterComp: Component.t<
          _,
          ReventlessSpec.Counter.outputs,
          ReventlessSpec.Counter.operations,
        > = counter->Obj.magic
        (counterComp->Component.operations, counterComp->Component.outputs->Some)
      },
    )

    module Set = Belt.Set.String
    let aggregateNames =
      Mappings.mappings
      ->Array.filterMap((module(Mapping: Mappings.Mapping)) =>
        if Mapping.Source.name != Counter.Source.name {
          Some(Mapping.Source.name)
        } else {
          None
        }
      )
      ->Set.fromArray

    let eventCollector = counterOperations->Pulumi.Output.apply(({count, addToCounterTarget}) =>
      {
        let eventTopics = allEventTopics->EventTopic.filter(aggregateNames)
        let eventCollector = SpecificEventCollector.make(~name, ~eventTopics, ~opts)

        module EventCollectorHandler = EventMapper_Callback.MakeEventCollectorHandler({
          let publishJsons = publishJsons
          let count = count
          let addToCounterTarget = addToCounterTarget
          let commonEventsHandler = CounterHandler.commonEventsHandler
        })
        let handler = SpecificEventCollector.makeHandler(
          ~eventCollector,
          ~eventsHandler=EventCollectorHandler.handleJsonEvents,
        )
        eventCollector->AggregateRuntimeBuilder.forEventCollector(
          ~handler,
          ~eventTopics,
          ~resources,
          ~memorySize,
          ~timeout,
        )

        eventCollector
      }->Component.outputs
    )

    let outputs: EventMapper.outputs = {
      name,
      eventCollector,
      counter: ?counterOutputs,
    }
    self->Component.setOutputs(outputs)
  }

  let make = (
    ~name,
    ~allEventTopics,
    ~queryEngine,
    ~publishJsons,
    ~resources,
    ~memorySize=2048,
    ~timeout=180,
    ~opts=?,
  ) =>
    Component.make(
      ~componentType=EventMapper.componentType->ComponentType.toString,
      ~name,
      ~construct=construct(
        ~allEventTopics,
        ~queryEngine,
        ~publishJsons,
        ~resources,
        ~memorySize,
        ~timeout,
        ...
      ),
      ~opts,
    )
}
