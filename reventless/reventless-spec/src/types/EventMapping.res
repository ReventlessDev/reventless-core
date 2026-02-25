module type Source = {
  let name: string
  module Id: Id.T
  @schema
  type event
}

module type Target = {
  let name: string
  module Id: Id.T
  @schema
  type command
}

type action<'id, 'command> =
  | Publish('id, 'command)
  | PublishDelayed('id, 'command, int)
  | PublishAsync(promise<array<('id, 'command)>>)
  | AddToCounterTarget(Counter.counterTarget)
  | Count(Counter.counterId)
  | CountMulti(Counter.counterId, int)

module type T = {
  module Source: Source
  module Target: Target
  let map: (
    Source.Id.t,
    Source.event,
    QueryEngine.operations,
  ) => array<action<Target.Id.t, Target.command>>
}
