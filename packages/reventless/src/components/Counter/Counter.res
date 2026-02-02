let componentType = ComponentType.Counter

type countItem = {
  counterId: ReventlessSpec.Counter.counterId,
  reference: ReventlessSpec.Counter.reference,
  inc: int,
}

type counterTargetRef = {
  counterId: ReventlessSpec.Counter.counterId,
  target: int,
  targetRef: ReventlessSpec.Counter.reference,
}

type count = array<countItem> => promise<unit>
type addToCounterTarget = counterTargetRef => promise<unit>

type counterEventsHandler = array<JSON.t> => promise<unit>

type t
type outputs = {referencesDb: QueryDb.outputs, countsDb: QueryDb.outputs}
type operations = {count: count, addToCounterTarget: addToCounterTarget}
type component = Component.t<t, outputs, operations>

type action =
  | Count(countItem)
  | AddToCounterTarget(counterTargetRef)

@schema
type counterEvent = CountFinished

module Source = {
  module Id = ReventlessSpec.Id.String
  let name = ComponentType.Counter->ComponentType.toName
  @schema
  type event = counterEvent
}

module type T = {
  let make: (
    ~name: string,
    ~counterEventsHandler: counterEventsHandler,
    ~ttl: int=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}

let separator = "#"
let makeId = ((counterId, reference)) => counterId ++ (separator ++ reference)
let unmakeId = id =>
  id
  ->String.split(separator)
  ->(
    x =>
      switch x {
      | [] => ("", "")
      | [counterId] => (counterId, "")
      | parts => (parts->Array.getUnsafe(0), parts->Array.getUnsafe(1))
      }
  )

@inline
let countFieldName = "count"
