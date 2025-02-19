let componentType = ComponentType.Counter

type count = array<Counter_Runtime.countItem> => Js.Promise.t<unit>
type addToCounterTarget = Counter_Runtime.counterTargetRef => Js.Promise.t<unit>

type counterEventsHandler = array<Js.Json.t> => Js.Promise.t<unit>

type t
type outputs = {referencesDb: QueryDb.outputs, countsDb: QueryDb.outputs}
type operations = {count: count, addToCounterTarget: addToCounterTarget}
type component = Component.t<t, outputs, operations>

type action =
  | Count(Counter_Runtime.countItem)
  | AddToCounterTarget(Counter_Runtime.counterTargetRef)

module Source = {
  module Id = ReventlessSpec.Id.String
  let name = ComponentType.Counter->ComponentType.toName
  @decco
  type event = Counter_Runtime.counterEvent
}

module type T = {
  let make: (
    ~name: string,
    ~counterEventsHandler: counterEventsHandler,
    ~ttl: int=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
