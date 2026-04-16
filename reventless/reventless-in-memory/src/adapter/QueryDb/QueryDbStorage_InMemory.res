// In-memory QueryDb storage.
// Make(Bus) functor: registers ops and scan function in the Bus so that
// QueryDbResolvers_GraphQL and QueryEngine_InMemory can look up data by read model name.
//
// Storage model: dict<dict<JSON.t>> — partition key → sub-key → item.
// When no subIdField is configured, all items are stored under the implicit sub-key "".

// Extract sub-key from an item's JSON using the given field name.
// Returns "" if the field is absent, not an object, or not a string.
let getSubKey = (item: JSON.t, subIdField: option<string>): string =>
  switch subIdField {
  | None => ""
  | Some(field) =>
    switch item->JSON.Decode.object {
    | Some(obj) =>
      switch obj->Dict.get(field) {
      | Some(v) => v->JSON.Decode.string->Option.getOr("")
      | None => ""
      }
    | None => ""
    }
  }

// Return items for a partition key, sorted alphabetically by sub-key.
let sortedItems = (store: dict<dict<JSON.t>>, partitionKey: string): array<JSON.t> =>
  switch store->Dict.get(partitionKey) {
  | None => []
  | Some(subMap) =>
    subMap
    ->Dict.toArray
    ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
    ->Array.map(((_, v)) => v)
  }

// Flatten partition → subKey → item store to a flat array.
// Injects "id" attribute if not already present on each item.
let flattenStore = (store: dict<dict<JSON.t>>): array<JSON.t> =>
  store
  ->Dict.toArray
  ->Array.flatMap(((id, subMap)) =>
    subMap
    ->Dict.toArray
    ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
    ->Array.map(((_, item)) => {
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
    ~subIdField=?,
    ~ttl as _=?,
    ~api as _,
    ~apiRole as _,
    ~opts as _,
  ) => {
    let store: ref<dict<dict<JSON.t>>> = ref(Dict.make())
    let allItems: ref<array<JSON.t>> = ref([])

    let syncAll = () => {
      allItems.contents = flattenStore(store.contents)
    }

    let getOrCreateSubMap = (partitionKey: string): dict<JSON.t> =>
      switch store.contents->Dict.get(partitionKey) {
      | Some(m) => m
      | None =>
        let m = Dict.make()
        store.contents->Dict.set(partitionKey, m)
        m
      }

    let load: QueryDb.load<string, JSON.t> = async id =>
      Ok(sortedItems(store.contents, id))

    let loadStream: QueryDb.loadStream<string, JSON.t> = id =>
      sortedItems(store.contents, id)->Stream.fromIterable

    let save: QueryDb.save<string, JSON.t> = async (id, state, _saveMode, _ttl) => {
      let subKey = getSubKey(state, subIdField)
      let subMap = getOrCreateSubMap(id)
      subMap->Dict.set(subKey, state)
      syncAll()
      Bus.publishStateChange(~name, ~state)
      Ok()
    }

    let saveBatch: QueryDb.saveBatch<string, JSON.t> = async batch => {
      batch->Array.forEach(((id, state, _ttl)) => {
        let subKey = getSubKey(state, subIdField)
        let subMap = getOrCreateSubMap(id)
        subMap->Dict.set(subKey, state)
      })
      syncAll()
      // Notify subscribers for each saved item
      batch->Array.forEach(((_, state, _)) => Bus.publishStateChange(~name, ~state))
      Ok()
    }

    let count: QueryDb.count<string> = async (_id, _fieldName, inc) => Ok(inc)

    let delete: QueryDb.delete<string> = async (id, subIdOpt) => {
      switch subIdOpt {
      | None => store.contents->Dict.delete(id)
      | Some((_, subValue)) =>
        switch store.contents->Dict.get(id) {
        | Some(subMap) => subMap->Dict.delete(subValue)
        | None => ()
        }
      }
      syncAll()
      Ok()
    }

    let deleteBatch: QueryDb.deleteBatch<string> = async ids => {
      ids->Array.forEach(((id, subIdOpt)) => {
        switch subIdOpt {
        | None => store.contents->Dict.delete(id)
        | Some((_, subValue)) =>
          switch store.contents->Dict.get(id) {
          | Some(subMap) => subMap->Dict.delete(subValue)
          | None => ()
          }
        }
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
