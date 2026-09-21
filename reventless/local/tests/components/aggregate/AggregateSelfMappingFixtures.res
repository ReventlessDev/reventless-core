// Regression fixtures for the event-mapping self-deadlock.
//
// An aggregate whose event mapping commands the aggregate that emitted the event:
// Placed → Ship, as the aggregates example's order auto-ships. Awaited inside the
// mapper's subscriber, the Ship command appends Shipped, which the bus cannot
// finish publishing until that same subscriber dequeues it — so the original
// Place never returned, and neither did the GraphQL request behind it.

module ShipmentSpec = {
  module Id = Reventless.Id.String
  let name = "TestShipment"

  @schema
  type command = Place | Ship

  @schema
  type event = Placed | Shipped

  @schema
  type error = unit

  let moduleUrl: string = %raw(`import.meta.url`)
}

module ShipmentBehavior: ReventlessCore.Behavior.T with module Spec := ShipmentSpec = {
  type state = int // events seen

  let initialState = 0
  let snapshot = None
  let moduleUrl: string = %raw(`import.meta.url`)

  let evolve = (state, _event: ShipmentSpec.event) => state + 1

  let decide = (state, command: ShipmentSpec.command) =>
    switch (state, command) {
    | (0, Place) => Ok([ShipmentSpec.Placed])
    | (1, Ship) => Ok([ShipmentSpec.Shipped])
    | _ => Ok([])
    }
}

module ShipmentMappings = {
  module M = Reventless.EventMapping.Mappings.Make(ShipmentSpec)
  module type Mapping = M.Mapping
  let moduleUrl: string = %raw(`import.meta.url`)

  module AutoShip = {
    module Source = ShipmentSpec
    let map = (id, event, _queryEngine) =>
      switch event {
      | ShipmentSpec.Placed => [Reventless.EventMapping.Publish(id, ShipmentSpec.Ship)]
      | Shipped => []
      }
  }

  let mappings: array<module(Mapping)> = [module(AutoShip)]
  let counter = None
}

module Bus = LocalBus.Make()

// Topic name = Spec.name ++ "Aggr" ++ "EventTopic"
let publishedEvents: ref<int> = ref(0)
let _ = Bus.subscribeToEvents("TestShipmentAggrEventTopic", async (_, _, _) => {
  publishedEvents := publishedEvents.contents + 1
})

let _ = TestRunner.setup()

module ShipmentAggregateMaker = Aggregate_Builder.Make(Bus)
module ShipmentAgg = ShipmentAggregateMaker.Make(ShipmentSpec, ShipmentBehavior, ShipmentMappings)

let agg = ShipmentAgg.make(~api=())

// A plugin attaches an aggregate's event mapper once every topic exists; with one
// aggregate, its own topic is all there is.
let aggOutputs = agg->ReventlessCore.Component.outputs
let _ = aggOutputs.addEventMapper(
  Dict.fromArray([(ShipmentSpec.name, aggOutputs.eventLog.eventTopic)]),
  TestFixtures.mockQueryEngine,
)

let withTimeout = async (p: promise<'a>, ~ms: int): result<'a, string> => {
  let timeout = Promise.make((resolve, _) => {
    let _ = setTimeout(() => resolve(Error("timed out")), ms)
  })
  await Promise.race([p->Promise.thenResolve(v => Ok(v)), timeout])
}
