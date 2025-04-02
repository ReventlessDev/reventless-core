module Make = (
  Target: ReventlessSpec.EventMapping.Target,
  SpecificEventCollector: EventCollector.T,
  Mappings: EventMapper.Mappings with module Target := Target,
  RuntimeEnvironment: Runtime.Environment,
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
          Counter.count: async _items => Js.log("No counter deployed, but trying to use count"),
          addToCounterTarget: async _target =>
            Js.log("No counter deployed, but trying to use addToCounterTarget"),
        }),
        None,
      ),
      (module(Counter: Counter.T)) => {
        let counter = Counter.make(
          ~name,
          ~counterEventsHandler=CounterHandler.handleCounterEvents,
          ~opts,
        )
        (counter->Component.operations, counter->Component.outputs->Some)
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
        let eventCollector = SpecificEventCollector.make(~name, ~opts)
        let opts = {Pulumi.ComponentResource.parent: eventCollector->Component.toPulumiResource}

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
        let runtime = RuntimeEnvironment.make(~name, ~handler, ~memorySize, ~timeout, ~opts)

        let eventTopics = allEventTopics->EventTopic.filter(aggregateNames)

        SpecificEventCollector.connect(
          ~name,
          ~eventTopics,
          ~eventCollector,
          ~runtime,
          ~resources,
          ~opts,
        )
        eventCollector
      }->Component.outputs
    )

    self->Component.setOutputs({
      EventMapper.name,
      eventCollector,
      counter: ?counterOutputs,
    })
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
      ~opts
    )
}
