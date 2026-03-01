// Mock in-memory QueryDb storage.
// Make(Bus) functor: registers ops and scan in the Bus (same as QueryDbStorage_InMemory).
// Adds reset() and failNextWrites counter for test isolation and failure injection.

module Make = (Bus: InMemory_Bus.T) => {
  open ReventlessCore

  type t = {
    storage: QueryDb_Adapter.storage,
    failNextWrites: ref<int>,
    reset: unit => unit,
  }

  let make = (
    ~name,
    ~indexes as _=[],
    ~subIdField as _=?,
    ~ttl as _=?,
    ~api as _=(),
    ~apiRole as _=(),
    ~opts as _: Pulumi.CustomResourceOptions.t={},
  ) => {
    let store: ref<dict<array<JSON.t>>> = ref(Dict.make())
    let allItems: ref<array<JSON.t>> = ref([])
    let failNextWrites = ref(0)

    let syncAll = () => {
      allItems.contents = store.contents->Dict.valuesToArray->Array.flatMap(v => v)
    }

    let load: QueryDb.load<string, JSON.t> = async id =>
      Ok(store.contents->Dict.get(id)->Option.getOr([]))

    let loadStream: QueryDb.loadStream<string, JSON.t> = id =>
      store.contents->Dict.get(id)->Option.getOr([])->Stream.fromIterable

    let save: QueryDb.save<string, JSON.t> = async (id, state, _saveMode, _ttl) => {
      if failNextWrites.contents > 0 {
        failNextWrites := failNextWrites.contents - 1
        Error(Reventless.QueryDb.NotSavedToStorage("mock write failure"))
      } else {
        store.contents->Dict.set(id, [state])
        syncAll()
        Ok()
      }
    }

    let saveBatch: QueryDb.saveBatch<string, JSON.t> = async batch => {
      if failNextWrites.contents > 0 {
        failNextWrites := failNextWrites.contents - 1
        Error(Reventless.QueryDb.BatchNotFullyWrittenToStorage("mock write failure"))
      } else {
        batch->Array.forEach(((id, state, _ttl)) => {
          store.contents->Dict.set(id, [state])
        })
        syncAll()
        Ok()
      }
    }

    let count: QueryDb.count<string> = async (_id, _fieldName, inc) => Ok(inc)

    let delete: QueryDb.delete<string> = async (id, _subId) => {
      store.contents->Dict.delete(id)
      syncAll()
      Ok()
    }

    let deleteBatch: QueryDb.deleteBatch<string> = async ids => {
      ids->Array.forEach(((id, _subId)) => {
        store.contents->Dict.delete(id)
      })
      syncAll()
      Ok()
    }

    let ops: QueryDb_Adapter.operations = {
      load,
      loadStream,
      save,
      saveBatch,
      count,
      delete,
      deleteBatch,
    }

    Bus.registerQueryDb(name, ops)
    Bus.registerQueryDbScan(name, () => allItems.contents)

    let storage: QueryDb_Adapter.storage = {
      resources: [],
      dataSourceName: ""->Pulumi.Output.make,
      operations: Pulumi.Output.make(ops),
    }

    let reset = () => {
      store := Dict.make()
      allItems := []
      failNextWrites := 0
    }

    {storage, failNextWrites, reset}
  }
}
