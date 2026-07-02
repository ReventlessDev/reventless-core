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
    registerQueryDbIndexLookup: Bus.registerQueryDbIndexLookup,
    registerQueryDbListPage: Bus.registerQueryDbListPage,
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
    // Lazy flattened snapshot for the registered scan/stream closures. The old
    // shape reflattened+resorted the *entire* store on every single-row write
    // (`syncAll`), so a projection replaying N events was O(n²). Instead each
    // mutation just marks the snapshot dirty; the scan closure reflattens once,
    // on demand, and only when something changed since the last read.
    let snapshot: ref<array<JSON.t>> = ref([])
    let dirty = ref(false)
    let syncAll = () => dirty := true
    let currentItems = () => {
      if dirty.contents {
        snapshot.contents = flattenStore(store.contents)
        dirty := false
      }
      snapshot.contents
    }

    // TTL parity with the SQLite backend (which filters on `expires_at`). We
    // record an absolute expiry (epoch seconds, the same value SQLite stores) per
    // (partition, sub-key) and drop expired entries lazily on read — a session
    // without reads never spends cycles expiring, matching SQLite's read-time
    // `notExpiredClause`. Previously `~ttl` was ignored entirely in memory.
    let expiries: ref<dict<dict<float>>> = ref(Dict.make())
    let nowSecs = () => Date.now() /. 1000.0
    let recordExpiry = (id: string, subKey: string, ttl: option<int>) =>
      switch ttl {
      | Some(t) =>
        let subExp = switch expiries.contents->Dict.get(id) {
        | Some(m) => m
        | None =>
          let m = Dict.make()
          expiries.contents->Dict.set(id, m)
          m
        }
        subExp->Dict.set(subKey, Int.toFloat(t))
      | None =>
        switch expiries.contents->Dict.get(id) {
        | Some(m) => m->Dict.delete(subKey)
        | None => ()
        }
      }
    let purgeExpired = () => {
      let now = nowSecs()
      let removedAny = ref(false)
      expiries.contents
      ->Dict.toArray
      ->Array.forEach(((id, subExp)) =>
        subExp
        ->Dict.toArray
        ->Array.forEach(((subKey, exp)) =>
          if exp <= now {
            switch store.contents->Dict.get(id) {
            | Some(sm) =>
              if sm->Dict.get(subKey)->Option.isSome {
                sm->Dict.delete(subKey)
                removedAny := true
              }
              if sm->Dict.keysToArray->Array.length == 0 {
                store.contents->Dict.delete(id)
              }
            | None => ()
            }
            subExp->Dict.delete(subKey)
          }
        )
      )
      if removedAny.contents {
        syncAll()
      }
    }

    let getOrCreateSubMap = (partitionKey: string): dict<JSON.t> =>
      switch store.contents->Dict.get(partitionKey) {
      | Some(m) => m
      | None =>
        let m = Dict.make()
        store.contents->Dict.set(partitionKey, m)
        m
      }

    let load: QueryDb.load<string, JSON.t> = async id => {
      purgeExpired()
      Ok(sortedItems(store.contents, id))
    }

    let loadStream: QueryDb.loadStream<string, JSON.t> = id => {
      purgeExpired()
      sortedItems(store.contents, id)->Stream.fromIterable
    }

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

    let save: QueryDb.save<string, JSON.t> = async (id, state, _saveMode, ttl) => {
      let subKey = getSubKey(state, subIdField)
      let subMap = getOrCreateSubMap(id)
      subMap->Dict.set(subKey, state)
      recordExpiry(id, subKey, ttl)
      syncAll()
      publishUpdated(id, state)
      Ok()
    }

    let saveBatch: QueryDb.saveBatch<string, JSON.t> = async batch => {
      batch->Array.forEach(((id, state, ttl)) => {
        let subKey = getSubKey(state, subIdField)
        let subMap = getOrCreateSubMap(id)
        subMap->Dict.set(subKey, state)
        recordExpiry(id, subKey, ttl)
      })
      syncAll()
      // Notify subscribers for each saved item
      batch->Array.forEach(((id, state, _)) => publishUpdated(id, state))
      Ok()
    }

    // Atomic-ish counter, mirroring DynamoDB's `ADD #fieldName :inc` on key {id}:
    // read the field on the partition-key item (counters are single-state, so the
    // implicit sub-key ""), add `inc`, persist, and return the NEW total. The
    // previous `Ok(inc)` echoed the increment and never touched the store, so the
    // running total was wrong and `loadStream` never reflected the counter.
    let count: QueryDb.count<string> = async (id, fieldName, inc) => {
      let subMap = getOrCreateSubMap(id)
      let existing = subMap->Dict.get("")->Option.flatMap(JSON.Decode.object)
      let current =
        existing
        ->Option.flatMap(o => o->Dict.get(fieldName))
        ->Option.flatMap(JSON.Decode.float)
        ->Option.mapOr(0, Float.toInt)
      let next = current + inc
      let obj = Dict.make()
      switch existing {
      | Some(o) => o->Dict.toArray->Array.forEach(((k, v)) => obj->Dict.set(k, v))
      | None => ()
      }
      obj->Dict.set("id", JSON.Encode.string(id))
      obj->Dict.set(fieldName, JSON.Encode.int(next))
      let newItem = JSON.Encode.object(obj)
      subMap->Dict.set("", newItem)
      syncAll()
      publishUpdated(id, newItem)
      Ok(next)
    }

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
    Bus.registerQueryDbScan(name, () => {
      purgeExpired()
      currentItems()
    })
    Bus.registerQueryDbStream(name, () => {
      purgeExpired()
      currentItems()->Stream.fromIterable
    })
    // Equality lookup on an indexed field. No real in-memory index (dev scale),
    // but reusing the lazy snapshot avoids reflattening per call and keeps result
    // parity with the SQLite `json_extract` push-down (both match string fields).
    Bus.registerQueryDbIndexLookup(name, (field, value) => {
      purgeExpired()
      currentItems()->Array.filter(item =>
        item
        ->JSON.Decode.object
        ->Option.flatMap(d => d->Dict.get(field))
        ->Option.flatMap(JSON.Decode.string)
        ->Option.map(v => v == value)
        ->Option.getOr(false)
      )
    })

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
