let storageErrorToString: ReventlessSpec.QueryDb.storageError => string = err =>
  switch err {
  | NotSavedToStorage(s) => `NotSavedToStorage(${s})`
  | NotLoadedFromStorage(s) => `NotLoadedFromStorage(${s})`
  | NotCountedOnStorage(s) => `NotCountedOnStorage(${s})`
  | NotDeletedFromStorage(s) => `NotDeletedFromStorage(${s})`
  | BatchNotFullyWrittenToStorage(s) => `BatchNotFullyWrittenToStorage(${s})`
  | StaleState => `StaleState`
  | MissingSubIdConfig => `MissingSubIdConfig`
  }

module Make = (Spec: ReventlessSpec.ReadModel.Spec.T) => {
  let decode = (id, item) =>
    switch Spec.state_decode(item) {
    | Ok(state) => [state]
    | Error(err) =>
      Js.log(
        `QueryDb: Error: Couldn't decode state for ${id->Spec.Id.toString}: ${err
          ->Js.Json.stringifyAny
          ->Belt.Option.getExn}`,
      )
      []
    }

  let loadFn = load =>
    async id =>
      switch await load(id->Spec.Id.toString) {
      | result =>
        result->Belt.Result.map(states =>
          states->Belt.Array.map(state => decode(id, state))->Belt.Array.concatMany
        )
      }

  let saveFn = save =>
    async (id, state, saveMode, ttl) =>
      switch state->Spec.state_encode->Js.Json.decodeObject {
      | Some(dict) =>
        dict->Js.Dict.set("id", Spec.Id.t_encode(id))
        let json = Js.Json.object_(dict)
        await save(id->Spec.Id.toString, json, saveMode, ttl)
      | None =>
        Js.log2("QueryDB.save: Error: Couldn't decodeObject:", state->Js.Json.stringifyAny)
        Belt.Result.Error(ReventlessSpec.QueryDb.NotSavedToStorage("Couldn't decodeObject"))
      }

  let saveBatchFn = saveBatch =>
    async items => {
      let batch = items->Belt.Array.keepMap(((id, state, ttl)) =>
        switch state->Spec.state_encode->Js.Json.decodeObject {
        | Some(dict) =>
          dict->Js.Dict.set("id", Spec.Id.t_encode(id))
          let json = Js.Json.object_(dict)
          Some((id->Spec.Id.toString, json, ttl))
        | None =>
          Js.log2("QueryDB.saveBatch: Error: Couldn't decodeObject:", state->Js.Json.stringifyAny)
          None
        }
      )
      await saveBatch(batch)
    }

  let countFn = count =>
    async (id, fieldName, inc) => await count(id->Spec.Id.toString, fieldName, inc)

  let deleteFn = delete => async (id, subId) => await delete(id->Spec.Id.toString, subId)

  let deleteBatchFn = deleteBatch =>
    async ids => {
      let ids = ids->Belt.Array.map(((id, sort)) => (id->Spec.Id.toString, sort))
      await deleteBatch(ids)
    }
}
