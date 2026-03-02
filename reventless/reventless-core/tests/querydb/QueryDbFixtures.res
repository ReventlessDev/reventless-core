S.enableJson()

// ─────────────────────────────────────────────────────────────
// Test state spec
// ─────────────────────────────────────────────────────────────

module ItemQueryDbSpec = {
  module Id = Reventless.Id.StringPure
  let name = "TestItemQueryDb"

  @schema
  type state = {name: string, count: int}

  let config = Reventless.ReadModel.config()
  let subIdConfig = None
}

// ─────────────────────────────────────────────────────────────
// Mock JSON storage operations
// ─────────────────────────────────────────────────────────────

let store: ref<dict<array<JSON.t>>> = ref(Dict.make())
let failNextWrite = ref(false)

let mockJsonOps: QueryDb.operations<string, JSON.t> = {
  load: async id => Ok(store.contents->Dict.get(id)->Option.getOr([])),
  loadStream: id => store.contents->Dict.get(id)->Option.getOr([])->Stream.fromIterable,
  save: async (id, state, _saveMode, _ttl) => {
    if failNextWrite.contents {
      failNextWrite := false
      Error(ReventlessInfra.QueryDb.NotSavedToStorage("mock failure"))
    } else {
      store.contents->Dict.set(id, [state])
      Ok()
    }
  },
  saveBatch: async batch => {
    if failNextWrite.contents {
      failNextWrite := false
      Error(ReventlessInfra.QueryDb.BatchNotFullyWrittenToStorage("mock failure"))
    } else {
      batch->Array.forEach(((id, state, _ttl)) => {
        store.contents->Dict.set(id, [state])
      })
      Ok()
    }
  },
  count: async (_id, _field, inc) => Ok(inc),
  delete: async (id, _subId) => {
    store.contents->Dict.delete(id)
    Ok()
  },
  deleteBatch: async ids => {
    ids->Array.forEach(((id, _subId)) => {
      store.contents->Dict.delete(id)
    })
    Ok()
  },
}

let reset = () => {
  store := Dict.make()
  failNextWrite := false
}
