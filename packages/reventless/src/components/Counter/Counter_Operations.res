@decco
type referencesState = {
  id: string,
  inc: int,
}

let groupCountItemsByCounterId = countItems => {
  let dict = Js.Dict.empty()
  countItems->Belt.Array.forEach(({Counter.counterId: counterId, reference}) => {
    let currentReferences = dict->Js.Dict.get(counterId)->Belt.Option.getWithDefault([])
    dict->Js.Dict.set(counterId, currentReferences->Array.concat([reference]))
  })
  dict->Js.Dict.entries
}

let logCountItems = countItems =>
  countItems
  ->groupCountItemsByCounterId
  ->Belt.Array.forEach(((counterId, references)) => {
    let size = references->Array.length
    let referencesStr = references->Js.Array2.joinWith(",")
    Js.log(`  ${size->Belt.Int.toString} reference(s) for counterId ${counterId}: ${referencesStr}`)
  })

exception NotCounted(string)

module type Spec = {
  let ttl: option<int>
  let saveBatch: QueryDb.saveBatch<string, referencesState>
}

module Make = (Spec: Spec) => {
  let count = async countItems => {
    let result = await Spec.saveBatch(
      countItems->Array.map(({Counter.counterId: counterId, reference, inc}) => {
        let id = Counter.makeId((counterId, reference))
        let state: referencesState = {id, inc}
        (id, state, Spec.ttl)
      }),
    )
    switch result {
    | Belt.Result.Ok(_) =>
      let batchSize = countItems->Array.length
      Js.log(__MODULE__ ++ `: saved batch of ${batchSize->Belt.Int.toString} reference(s):`)
      countItems->logCountItems
    | Error(ReventlessSpec.QueryDb.NotSavedToStorage(err)) =>
      let batchSize = countItems->Array.length
      Js.log(`Counter error: couldn't save batch of ${batchSize->Belt.Int.toString} reference(s):`)
      countItems->logCountItems
      raise(NotCounted(err))
    | Error(_) =>
      let batchSize = countItems->Array.length
      Js.log(
        `Unknown Counter error: couldn't save batch of ${batchSize->Belt.Int.toString} reference(s):`,
      )
      countItems->logCountItems
      raise(NotCounted("Unknown error"))
    }
  }
}
