@schema
type referencesState = {
  id: string,
  inc: int,
}

let groupCountItemsByCounterId = countItems => {
  let dict = Dict.make()
  countItems->Array.forEach(({ReventlessInfra.Counter.counterId: counterId, reference}) => {
    let currentReferences = dict->Dict.get(counterId)->Option.getOr([])
    dict->Dict.set(counterId, currentReferences->Array.concat([reference]))
  })
  dict->Dict.toArray
}

let logCountItems = countItems =>
  countItems
  ->groupCountItemsByCounterId
  ->Array.forEach(((counterId, references)) => {
    let size = references->Array.length
    let referencesStr = references->Array.joinUnsafe(",")
    Effect.logInfo(
      `  ${size->Int.toString} reference(s) for counterId ${counterId}: ${referencesStr}`,
    )->Effect.runSync
  })

exception NotCounted(string)

module type Ops = {
  let ttl: option<int>
  let saveBatch: QueryDb.saveBatch<string, referencesState>
}

module Make = (Ops: Ops) => {
  let count = async countItems => {
    let result = await Ops.saveBatch(
      countItems->Array.map(({ReventlessInfra.Counter.counterId: counterId, reference, inc}) => {
        let id = Counter.makeId((counterId, reference))
        let state: referencesState = {id, inc}
        (id, state, Ops.ttl)
      }),
    )
    switch result {
    | Ok(_) =>
      let batchSize = countItems->Array.length
      Effect.logInfo(
        __MODULE__ ++ `: saved batch of ${batchSize->Int.toString} reference(s):`,
      )->Effect.runSync
      countItems->logCountItems
    | Error(ReventlessInfra.QueryDb.NotSavedToStorage(err)) =>
      let batchSize = countItems->Array.length
      Effect.logError(
        `Counter error: couldn't save batch of ${batchSize->Int.toString} reference(s):`,
      )->Effect.runSync
      countItems->logCountItems
      throw(NotCounted(err))
    | Error(_) =>
      let batchSize = countItems->Array.length
      Effect.logError(
        `Unknown Counter error: couldn't save batch of ${batchSize->Int.toString} reference(s):`,
      )->Effect.runSync
      countItems->logCountItems
      throw(NotCounted("Unknown error"))
    }
  }
}
