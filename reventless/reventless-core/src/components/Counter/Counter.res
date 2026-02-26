let componentType = ComponentType.Counter

type countItem = Reventless.Counter.countItem
type counterTargetRef = Reventless.Counter.counterTargetRef

type count = Reventless.Counter.count
type addToCounterTarget = Reventless.Counter.addToCounterTarget

type counterEventsHandler = array<JSON.t> => promise<unit>

type t
type outputs = Reventless.Counter.outputs
type operations = Reventless.Counter.operations
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

module type T = Reventless.Counter.T

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
