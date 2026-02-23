// In-memory QueryDb storage.
// Simple dict-based key-value store for read model state.

open Reventless

type api = unit
type role = unit

let make: QueryDb_Adapter.storageMaker<unit, unit> = (
  ~name as _,
  ~indexes as _,
  ~subIdField as _=?,
  ~ttl as _=?,
  ~api as _,
  ~apiRole as _,
  ~opts as _,
) => {
  let store: ref<dict<array<JSON.t>>> = ref(Dict.make())

  let load: QueryDb.load<string, JSON.t> = async id =>
    Ok(store.contents->Dict.get(id)->Option.getOr([]))

  let save: QueryDb.save<string, JSON.t> = async (id, state, _saveMode, _ttl) => {
    store.contents->Dict.set(id, [state])
    Ok()
  }

  let saveBatch: QueryDb.saveBatch<string, JSON.t> = async batch => {
    batch->Array.forEach(((id, state, _ttl)) => {
      store.contents->Dict.set(id, [state])
    })
    Ok()
  }

  let count: QueryDb.count<string> = async (_id, _fieldName, inc) => Ok(inc)

  let delete: QueryDb.delete<string> = async (id, _subId) => {
    store.contents->Dict.delete(id)
    Ok()
  }

  let deleteBatch: QueryDb.deleteBatch<string> = async ids => {
    ids->Array.forEach(((id, _subId)) => {
      store.contents->Dict.delete(id)
    })
    Ok()
  }

  let ops: QueryDb_Adapter.operations = {
    load,
    save,
    saveBatch,
    count,
    delete,
    deleteBatch,
  }

  {
    resources: [],
    dataSourceName: ""->Pulumi.Output.make,
    operations: Pulumi.Output.make(ops),
  }
}
