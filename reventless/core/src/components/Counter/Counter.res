let componentType = ComponentType.Counter

type countItem = ReventlessInfra.Counter.countItem
type counterTargetRef = ReventlessInfra.Counter.counterTargetRef

type count = ReventlessInfra.Counter.count
type addToCounterTarget = ReventlessInfra.Counter.addToCounterTarget

type jsonEventsHandler = Stream.t<JSON.t, string, unit> => Effect.t<unit, string, unit>

type t
type outputs = ReventlessInfra.Counter.outputs
type operations = ReventlessInfra.Counter.operations
type component = Component.t<t, outputs, operations>

type action =
  | Count(countItem)
  | AddToCounterTarget(counterTargetRef)

@schema
type counterEvent = CountFinished

module Source = {
  module Id = Reventless.Id.String
  let name = ComponentType.Counter->ComponentType.toName
  @schema
  type event = counterEvent
}

module type T = ReventlessInfra.Counter.T

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
