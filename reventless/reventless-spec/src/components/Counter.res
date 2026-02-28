type counterId = string
type reference = string

type counterTarget = {
  counterId: counterId,
  target: int,
}

type countItem = {
  counterId: counterId,
  reference: reference,
  inc: int,
}

type counterTargetRef = {
  counterId: counterId,
  target: int,
  targetRef: reference,
}

type outputs = {referencesDb: QueryDb.outputs, countsDb: QueryDb.outputs}
type count = array<countItem> => promise<unit>
type addToCounterTarget = counterTargetRef => promise<unit>
type operations = {count: count, addToCounterTarget: addToCounterTarget}

type jsonEventsHandler = Stream.t<JSON.t, string, unit> => Effect.t<unit, string, unit>

module type T = {
  type component
  let make: (
    ~name: string,
    ~jsonEventsHandler: jsonEventsHandler,
    ~ttl: int=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
