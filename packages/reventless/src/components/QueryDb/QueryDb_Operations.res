module type Spec = {
  let jsonOps: QueryDb.operations<string, Js.Json.t>
}

module Make = (ReadModelSpec: ReventlessSpec.ReadModel_Spec.T, Spec: Spec) => {
  let decode = (id, item) =>
    switch ReadModelSpec.state_decode(item) {
    | Ok(state) => [state]
    | Error(err) =>
      Js.log(
        `QueryDb: Error: Couldn't decode state for ${id->ReadModelSpec.Id.toString}: ${err
          ->Js.Json.stringifyAny
          ->Belt.Option.getExn}`,
      )
      []
    }

  let load = async id =>
    switch await Spec.jsonOps.load(id->ReadModelSpec.Id.toString) {
    | result =>
      result->Belt.Result.map(states => states->Array.map(state => decode(id, state))->Array.flat)
    }

  let save = async (id, state, saveMode, ttl) =>
    switch state->ReadModelSpec.state_encode->Js.Json.decodeObject {
    | Some(dict) =>
      dict->Js.Dict.set("id", ReadModelSpec.Id.t_encode(id))
      let json = Js.Json.object_(dict)
      await Spec.jsonOps.save(id->ReadModelSpec.Id.toString, json, saveMode, ttl)
    | None =>
      Js.log2("QueryDB.saveState: Error: Couldn't decodeObject:", state->Js.Json.stringifyAny)
      Belt.Result.Error(ReventlessSpec.QueryDb.NotSavedToStorage("Couldn't decodeObject"))
    }

  let saveBatch = async items => {
    let batch = items->Array.filterMap(((id, state, ttl)) =>
      switch state->ReadModelSpec.state_encode->Js.Json.decodeObject {
      | Some(dict) =>
        dict->Js.Dict.set("id", ReadModelSpec.Id.t_encode(id))
        let json = Js.Json.object_(dict)
        Some((id->ReadModelSpec.Id.toString, json, ttl))
      | None =>
        Js.log2("QueryDB.saveStates: Error: Couldn't decodeObject:", state->Js.Json.stringifyAny)
        None
      }
    )
    await Spec.jsonOps.saveBatch(batch)
  }

  let count = async (id, fieldName, inc) =>
    await Spec.jsonOps.count(id->ReadModelSpec.Id.toString, fieldName, inc)

  let delete = async (id, subId) => await Spec.jsonOps.delete(id->ReadModelSpec.Id.toString, subId)

  let deleteBatch = async ids => {
    let ids = ids->Array.map(((id, sort)) => (id->ReadModelSpec.Id.toString, sort))
    await Spec.jsonOps.deleteBatch(ids)
  }
}
