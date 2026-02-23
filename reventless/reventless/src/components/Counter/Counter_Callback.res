@schema
type countsState = {
  id: string,
  count: int,
} //TODO: generalize

type counterHandler = (~references: array<(string, int)>, ~counts: array<JSON.t>) => promise<unit>

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
  let counterEventsHandler: Counter.counterEventsHandler
}

module Make = (Spec: Spec) => {
  let counterHandler = async (~references, ~counts) => {
    Console.log2("counterHandler: references:", references->Array.length)
    Console.log2("counterHandler: counts:", counts)
    await references
    ->groupByCounterId
    ->Array.map(((counterId, dec)) =>
      Spec.countsDbCount(
        counterId->ReventlessSpec.Id.StringPure.makeFromString,
        Counter.countFieldName,
        -dec,
      )
    )
    ->Promise.all
    ->Util.Promise.toUnit
    // TODO error handling

    await Spec.counterEventsHandler(
      counts->Array.filterMap(state =>
        switch state->Message.decode(countsStateSchema) {
        | {id, count} if count == 0 =>
          let (counterId, _) = id->Counter.unmakeId
          Console.log(
            __MODULE__ ++
            `.counterHandler: counted down ${Spec.name}(${id}) to ${count->Int.toString}`,
          )
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
          Console.log(
            __MODULE__ ++
            `.counterHandler: counted down ${Spec.name}(${id}) to ${count->Int.toString}`,
          )
          None
        }
      ),
    )
  }
}
