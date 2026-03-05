@schema
type countsState = {
  id: string,
  count: int,
} //TODO: generalize

type counterHandler = (~references: array<(string, int)>, ~counts: array<JSON.t>) => promise<unit>

// Aggregates reference increments by counter ID: [("c1#ref-a", 1), ("c1#ref-b", 2)] → [("c1", 3)]
let groupByCounterId = references => {
  let dict = Dict.make()
  references->Array.forEach(((reference, inc)) => {
    let counterId = reference->Counter.unmakeId->Pair.first
    let current = dict->Dict.get(counterId)->Option.getOr(0)
    dict->Dict.set(counterId, current + inc)
  })
  dict->Dict.toArray
}

module type Spec = {
  let name: string
  let countsDbCount: QueryDb.count<string>
  let jsonEventsHandler: Counter.jsonEventsHandler
}

module Make = (Spec: Spec) => {
  // Handles a DynamoDB Streams batch of counter changes:
  //   1. Decrements each counter's count in the QueryDb (grouped by counter ID)
  //   2. Emits CountFinished events for any counters that reached zero
  // Builds an Effect pipeline and converts to promise at the boundary (type = promise<unit>).
  let counterHandler = (~references, ~counts) =>
    Effect.logInfo(
      `counterHandler: references: ${references->Array.length->Int.toString}`,
    )
    ->Effect.zipRight(
      Effect.logInfo(
        `counterHandler: counts: ${counts->JSON.stringifyAny->Option.getOr("[]")}`,
      )
    )
    ->Effect.zipRight(
      Effect.all(
        references
        ->groupByCounterId
        ->Array.map(((counterId, dec)) =>
          Effect.promise(() =>
            Spec.countsDbCount(
              counterId->Reventless.Id.StringPure.makeFromString,
              Counter.countFieldName,
              -dec,
            )
          )
        ),
        {"concurrency": "unbounded"},
      )->Effect.map(_ => ())
    )
    ->Effect.zipRight(
      Spec.jsonEventsHandler(
        Stream.fromIterable(
          counts->Array.filterMap(state =>
            switch state->Message.decode(countsStateSchema) {
            | {id, count} if count == 0 =>
              let (counterId, _) = id->Counter.unmakeId
              Effect.logInfo(
                __MODULE__ ++
                `.counterHandler: counted down ${Spec.name}(${id}) to ${count->Int.toString}`,
              )->Effect.runSync
              let meta = Message.generateMeta(
                ~service=ComponentType.Counter->ComponentType.toName,
                ~user="Counter",
              )
              Some(
                [
                  ("id", counterId->JSON.Encode.string),
                  ("meta", meta->Message.encode(Message.metaSchema)),
                  ("event", Counter.CountFinished->Message.encode(Counter.counterEventSchema)),
                ]
                ->Dict.fromArray
                ->JSON.Encode.object,
              )
            | {id, count} =>
              Effect.logInfo(
                __MODULE__ ++
                `.counterHandler: counted down ${Spec.name}(${id}) to ${count->Int.toString}`,
              )->Effect.runSync
              None
            }
          ),
        ),
      )
    )
    ->Effect.runPromise
}
