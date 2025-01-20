@decco
type referencesState = {
  id: string,
  inc: int,
}

@decco
type countsState = {
  id: string,
  count: int,
} //TODO: generalize

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

type counterHandler = (
  ~references: array<(string, int)>,
  ~counts: array<Js.Json.t>,
) => Js.Promise.t<unit>

let separator = "#"
let makeId = ((counterId, reference)) => counterId ++ (separator ++ reference)
let unmakeId = id =>
  id
  ->Js.String2.split(separator)
  ->(
    x =>
      switch x {
      | [] => ("", "")
      | [counterId] => (counterId, "")
      | parts => (parts->Array.getUnsafe(0), parts->Array.getUnsafe(1))
      }
  )

let groupCountItemsByCounterId = countItems => {
  let dict = Js.Dict.empty()
  countItems->Belt.Array.forEach(({counterId, reference}) => {
    let currentReferences = dict->Js.Dict.get(counterId)->Belt.Option.getWithDefault([])
    dict->Js.Dict.set(counterId, currentReferences->Belt.Array.concat([reference]))
  })
  dict->Js.Dict.entries
}

let logCountItems = countItems =>
  countItems
  ->groupCountItemsByCounterId
  ->Belt.Array.forEach(((counterId, references)) => {
    let size = references->Belt.Array.size
    let referencesStr = references->Js.Array2.joinWith(",")
    Js.log(`  ${size->Belt.Int.toString} reference(s) for counterId ${counterId}: ${referencesStr}`)
  })

exception NotCounted(string)

let count = ttl =>
  async (saveBatch, countItems) => {
    let result = await saveBatch(
      countItems->Belt.Array.map(({counterId, reference, inc}) => {
        let id = makeId((counterId, reference))
        let state: referencesState = {id, inc}
        (id, state, ttl)
      }),
    )
    switch result {
    | Belt.Result.Ok(_) =>
      let batchSize = countItems->Belt.Array.size
      Js.log(__MODULE__ ++ `: saved batch of ${batchSize->Belt.Int.toString} reference(s):`)
      countItems->logCountItems
    | Error(ReventlessSpec.QueryDb.NotSavedToStorage(err)) =>
      let batchSize = countItems->Belt.Array.size
      Js.log(`Counter error: couldn't save batch of ${batchSize->Belt.Int.toString} reference(s):`)
      countItems->logCountItems
      raise(NotCounted(err))
    | Error(_) =>
      let batchSize = countItems->Belt.Array.size
      Js.log(
        `Unknown Counter error: couldn't save batch of ${batchSize->Belt.Int.toString} reference(s):`,
      )
      countItems->logCountItems
      raise(NotCounted("Unknown error"))
    }
  }

let groupByCounterId = references => {
  let dict = Js.Dict.empty()
  references->Belt.Array.forEach(((reference, inc)) => {
    let counterId = reference->unmakeId->fst
    let current = dict->Js.Dict.get(counterId)->Belt.Option.getWithDefault(0)
    dict->Js.Dict.set(counterId, current + inc)
  })
  dict->Js.Dict.entries
}

@inline
let countFieldName = "count"

@decco
type counterEvent = CountFinished

let counterHandler = (name, countsDbCount, counterEventsHandler) =>
  async (~references, ~counts) => {
    Js.log2("counterHandler: references:", references->Belt.Array.size)
    Js.log2("counterHandler: counts:", counts)
    await references
    ->groupByCounterId
    ->Belt.Array.map(((counterId, dec)) =>
      countsDbCount(counterId->ReventlessSpec.Id.StringPure.makeFromString, countFieldName, -dec)
    )
    ->Js.Promise.all
    ->Util.Promise.toUnit
    // TODO error handling

    await counterEventsHandler(
      counts->Belt.Array.keepMap(state =>
        switch state->countsState_decode {
        | Ok({id, count}) if count == 0 =>
          let (counterId, _) = id->unmakeId
          Js.log(
            __MODULE__ ++
            `.counterHandler: counted down ${name}(${id}) to ${count->Belt.Int.toString}`,
          )
          let meta = Message.generateMeta(
            ~service=ComponentType.Counter->ComponentType.toName,
            ~user="Counter",
          )
          Some(
            [
              ("id", counterId->Js.Json.string),
              ("meta", meta->Message.meta_encode),
              ("event", CountFinished->counterEvent_encode),
            ]
            ->Js.Dict.fromArray
            ->Js.Json.object_,
          )
        | Ok({id, count}) =>
          Js.log(
            __MODULE__ ++
            `.counterHandler: counted down ${name}(${id}) to ${count->Belt.Int.toString}`,
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
