module Make = (
  Target: ReventlessSpec.EventMapping.Target,
  EventCollector: EventCollector.T,
  Mappings: EventMapper.Mappings with module Target := Target,
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
        (counter->Component.operations, counter->Component.extractOutputs->Some)
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
        module EventCollectorHandler = EventMapper_Callback.MakeEventCollectorHandler({
          let publishJsons = publishJsons
          let count = count
          let addToCounterTarget = addToCounterTarget
          let commonEventsHandler = CounterHandler.commonEventsHandler
        })

        EventCollector.make(
          ~name=Target.name->ComponentType.name(EventMapper.componentType),
          ~eventTopics=allEventTopics->Util.EventTopic.filterEventTopics(aggregateNames),
          ~eventsHandler=EventCollectorHandler.eventCollectorEventsHandler,
          ~memorySize,
          ~timeout,
          ~policy1=Pulumi.Output.make(None),
          ~policy2=Pulumi.Output.make(None),
          ~opts=Some(opts),
        )
      }->Component.extractOutputs
    )

    self->Component.setOutputs({
      EventMapper.name,
      eventCollector,
      counter: ?counterOutputs,
    })
  }

  let make = (
    ~allEventTopics,
    ~queryEngine,
    ~publishJsons,
    ~memorySize=2048,
    ~timeout=180,
    ~opts=?,
  ) =>
    Component.make(
      ~componentType=EventMapper.componentType->ComponentType.toString,
      ~name=Target.name,
      ~construct=construct(
        ~allEventTopics,
        ~queryEngine,
        ~publishJsons,
        ~memorySize,
        ~timeout,
        ...
      ),
      ~opts,
    )
}
