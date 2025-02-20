@decco
type countsState = {
  id: string,
  count: int,
} //TODO: generalize

type counterHandler = (
  ~references: array<(string, int)>,
  ~counts: array<Js.Json.t>,
) => Js.Promise.t<unit>

let groupByCounterId = references => {
  let dict = Js.Dict.empty()
  references->Belt.Array.forEach(((reference, inc)) => {
    let counterId = reference->Counter.unmakeId->fst
    let current = dict->Js.Dict.get(counterId)->Belt.Option.getWithDefault(0)
    dict->Js.Dict.set(counterId, current + inc)
  })
  dict->Js.Dict.entries
}

module type Spec = {
  let name: string
  let countsDbCount: QueryDb.count<string>
  let counterEventsHandler: Counter.counterEventsHandler
}

module Make = (Spec: Spec) => {
  let counterHandler = async (~references, ~counts) => {
    Js.log2("counterHandler: references:", references->Belt.Array.size)
    Js.log2("counterHandler: counts:", counts)
    await references
    ->groupByCounterId
    ->Belt.Array.map(((counterId, dec)) =>
      Spec.countsDbCount(
        counterId->ReventlessSpec.Id.StringPure.makeFromString,
        Counter.countFieldName,
        -dec,
      )
    )
    ->Js.Promise.all
    ->Util.Promise.toUnit
    // TODO error handling

    await Spec.counterEventsHandler(
      counts->Belt.Array.keepMap(state =>
        switch state->countsState_decode {
        | Ok({id, count}) if count == 0 =>
          let (counterId, _) = id->Counter.unmakeId
          Js.log(
            __MODULE__ ++
            `.counterHandler: counted down ${Spec.name}(${id}) to ${count->Belt.Int.toString}`,
          )
          let meta = Message.generateMeta(
            ~service=ComponentType.Counter->ComponentType.toName,
            ~user="Counter",
          )
          Some(
            [
              ("id", counterId->Js.Json.string),
              ("meta", meta->Message.meta_encode),
              ("event", CountFinished->Counter.counterEvent_encode),
            ]
            ->Js.Dict.fromArray
            ->Js.Json.object_,
          )
        | Ok({id, count}) =>
          Js.log(
            __MODULE__ ++
            `.counterHandler: counted down ${Spec.name}(${id}) to ${count->Belt.Int.toString}`,
          )
          None
        | _ =>
          let stateStr = state->Js.Json.stringify
          Js.log(__MODULE__ ++ `.counterHandler: couldn't decode state ${stateStr}`)
          None
        }
      ),
    )
  }
}
