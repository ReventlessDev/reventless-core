// In-memory QueryDb storage.
// Make(Bus) functor: registers ops and scan function in the Bus so that
// QueryDbResolvers_GraphQL and LocalQueryEngine can look up data by read model name.
//
// Storage model: dict<dict<JSON.t>> — partition key → sub-key → item.
// When no subIdField is configured, all items are stored under the implicit sub-key "".
//
// When BackendState is set to Sqlite, the `Make(Bus)` functor delegates to
// QueryDbStorage_Sqlite at `make` time so the same builder wiring serves
// both backends.

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

module Make = (Bus: LocalBus.T) => {
  open ReventlessCore

  type api = unit
  type role = unit

  let sqliteBusCallbacks: QueryDbStorage_Sqlite.busCallbacks = {
    publishStateChange: Bus.publishStateChange,
    registerQueryDb: Bus.registerQueryDb,
    registerQueryDbScan: Bus.registerQueryDbScan,
    registerQueryDbStream: Bus.registerQueryDbStream,
  }

  let makeMemory: QueryDb_Adapter.storageMaker<unit, unit> = (
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

    // Entity key matches the AWS StateTopic Lambda output (Phase 1):
    // single-key tables → partition value; composite tables → `pk-sk`.
    let entityKeyFor = (id: string, subKey: string): string =>
      switch subIdField {
      | Some(_) => id ++ "-" ++ subKey
      | None => id
      }

    let publishUpdated = (id: string, state: JSON.t) => {
      let subKey = getSubKey(state, subIdField)
      let descriptor = LocalBus.makeStateChangeDescriptor(
        ~changeKind="Updated",
        ~id=entityKeyFor(id, subKey),
        ~state=Some(state),
      )
      Bus.publishStateChange(~name, ~descriptor)
    }

    let publishRemoved = (id: string, subKey: string) => {
      let descriptor = LocalBus.makeStateChangeDescriptor(
        ~changeKind="Removed",
        ~id=entityKeyFor(id, subKey),
        ~state=None,
      )
      Bus.publishStateChange(~name, ~descriptor)
    }

    let save: QueryDb.save<string, JSON.t> = async (id, state, _saveMode, _ttl) => {
      let subKey = getSubKey(state, subIdField)
      let subMap = getOrCreateSubMap(id)
      subMap->Dict.set(subKey, state)
      syncAll()
      publishUpdated(id, state)
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
      batch->Array.forEach(((id, state, _)) => publishUpdated(id, state))
      Ok()
    }

    let count: QueryDb.count<string> = async (_id, _fieldName, inc) => Ok(inc)

    let delete: QueryDb.delete<string> = async (id, subIdOpt) => {
      switch subIdOpt {
      | None =>
        let subKeys = switch store.contents->Dict.get(id) {
        | Some(subMap) => subMap->Dict.keysToArray
        | None => []
        }
        store.contents->Dict.delete(id)
        syncAll()
        subKeys->Array.forEach(subKey => publishRemoved(id, subKey))
      | Some((_, subValue)) =>
        switch store.contents->Dict.get(id) {
        | Some(subMap) =>
          let hadIt = subMap->Dict.get(subValue)->Option.isSome
          subMap->Dict.delete(subValue)
          syncAll()
          if hadIt {
            publishRemoved(id, subValue)
          }
        | None => syncAll()
        }
      }
      Ok()
    }

    let deleteBatch: QueryDb.deleteBatch<string> = async ids => {
      let removed: array<(string, string)> = []
      ids->Array.forEach(((id, subIdOpt)) => {
        switch subIdOpt {
        | None =>
          switch store.contents->Dict.get(id) {
          | Some(subMap) =>
            subMap->Dict.keysToArray->Array.forEach(sk => removed->Array.push((id, sk)))
          | None => ()
          }
          store.contents->Dict.delete(id)
        | Some((_, subValue)) =>
          switch store.contents->Dict.get(id) {
          | Some(subMap) =>
            if subMap->Dict.get(subValue)->Option.isSome {
              removed->Array.push((id, subValue))
            }
            subMap->Dict.delete(subValue)
          | None => ()
          }
        }
      })
      syncAll()
      removed->Array.forEach(((id, subKey)) => publishRemoved(id, subKey))
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

  let make: QueryDb_Adapter.storageMaker<unit, unit> = (
    ~name,
    ~indexes,
    ~subIdField=?,
    ~ttl=?,
    ~api,
    ~apiRole,
    ~opts,
  ) =>
    switch BackendState.getDb() {
    | Some(db) =>
      QueryDbStorage_Sqlite.makeStorage(~db, ~bus=sqliteBusCallbacks, ~name, ~indexes, ~subIdField)
    | None => makeMemory(~name, ~indexes, ~subIdField?, ~ttl?, ~api, ~apiRole, ~opts)
    }
}
