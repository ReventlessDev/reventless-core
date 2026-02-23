let componentType = ComponentType.Counter

type countItem = ReventlessSpec.Counter.countItem
type counterTargetRef = ReventlessSpec.Counter.counterTargetRef

type count = ReventlessSpec.Counter.count
type addToCounterTarget = ReventlessSpec.Counter.addToCounterTarget

type counterEventsHandler = array<JSON.t> => promise<unit>

type t
type outputs = ReventlessSpec.Counter.outputs
type operations = ReventlessSpec.Counter.operations
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

module type T = ReventlessSpec.Counter.T

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
