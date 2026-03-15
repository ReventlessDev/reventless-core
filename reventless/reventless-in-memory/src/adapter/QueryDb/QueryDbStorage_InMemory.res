// In-memory QueryDb storage.
// Make(Bus) functor: registers ops and scan function in the Bus so that
// QueryDbResolvers_GraphQL and QueryEngine_InMemory can look up data by read model name.

let flattenWithId = (store: dict<array<JSON.t>>): array<JSON.t> =>
  store
  ->Dict.toArray
  ->Array.flatMap(((id, items)) =>
    items->Array.map(item => {
      let obj = item->JSON.Decode.object->Option.getOr(Dict.make())
      if !(obj->Dict.get("id")->Option.isSome) {
        let copy = Dict.make()
        obj->Dict.toArray->Array.forEach(((k, v)) => copy->Dict.set(k, v))
        copy->Dict.set("id", JSON.Encode.string(id))
        JSON.Encode.object(copy)
      } else {
        item
      }
    })
  )

module Make = (Bus: InMemory_Bus.T) => {
  open ReventlessCore

  type api = unit
  type role = unit

  let make: QueryDb_Adapter.storageMaker<unit, unit> = (
    ~name,
    ~indexes as _,
    ~subIdField as _=?,
    ~ttl as _=?,
    ~api as _,
    ~apiRole as _,
    ~opts as _,
  ) => {
    let store: ref<dict<array<JSON.t>>> = ref(Dict.make())
    let allItems: ref<array<JSON.t>> = ref([])

    let syncAll = () => {
      allItems.contents = flattenWithId(store.contents)
    }

    let load: QueryDb.load<string, JSON.t> = async id =>
      Ok(store.contents->Dict.get(id)->Option.getOr([]))

    let loadStream: QueryDb.loadStream<string, JSON.t> = id =>
      store.contents->Dict.get(id)->Option.getOr([])->Stream.fromIterable

    let save: QueryDb.save<string, JSON.t> = async (id, state, _saveMode, _ttl) => {
      store.contents->Dict.set(id, [state])
      syncAll()
      Ok()
    }

    let saveBatch: QueryDb.saveBatch<string, JSON.t> = async batch => {
      batch->Array.forEach(((id, state, _ttl)) => {
        store.contents->Dict.set(id, [state])
      })
      syncAll()
      Ok()
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
    Bus.registerQueryDbStream(name, () => allItems.contents->Stream.fromIterable)

    {
      resources: [],
      dataSourceName: ""->Pulumi.Output.make,
      operations: Pulumi.Output.make(ops),
    }
  }
}
