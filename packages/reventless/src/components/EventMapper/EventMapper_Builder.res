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

    let (counterOperations, counterOutputs) = Mappings.counter->Belt.Option.mapWithDefault(
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
          ~counterEventsHandler=CounterHandler.counterEventsHandler,
          ~opts,
        )
        (counter->Component.operations, counter->Component.outputs->Some)
      },
    )

    module Set = Belt.Set.String
    let aggregateNames =
      Mappings.mappings
      ->Belt.Array.keepMap((module(Mapping: Mappings.Mapping)) =>
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
        let channel = eventCollector->SpecificEventCollector.channel

        module EventCollectorHandler = EventMapper_Callback.MakeEventCollectorHandler({
          let publishJsons = publishJsons
          let count = count
          let addToCounterTarget = addToCounterTarget
          let commonEventsHandler = CounterHandler.commonEventsHandler
        })
        let handler = SpecificEventCollector.makeHandler(
          ~channel,
          ~eventsHandler=EventCollectorHandler.handleJsonEvents,
        )
        let runtime = RuntimeEnvironment.make(~name, ~handler, ~memorySize, ~timeout, ~opts)

        let _subscribeResources = SpecificEventCollector.subscribe(
          ~name,
          ~eventTopics=allEventTopics->Util.EventTopic.filterEventTopics(aggregateNames),
          ~channel,
          ~runtime,
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
        ~memorySize,
        ~timeout,
        ...
      ),
      ~opts
    )
}
