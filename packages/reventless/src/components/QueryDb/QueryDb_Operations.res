module type Ops = {
  let jsonOps: QueryDb.operations<string, JSON.t>
}

module Make = (ReadModelSpec: ReventlessSpec.ReadModel_Spec.T, Ops: Ops) => {
  let decode = (id, stateJson) =>
    switch stateJson->Message.decode(ReadModelSpec.stateSchema) {
    | state => [state]
    | exception err =>
      Console.log(
        `QueryDb: Error: Couldn't decode state for ${id->ReadModelSpec.Id.toString}: ${err
          ->JSON.stringifyAny
          ->Option.getOrThrow}`,
      )
      []
    }

  let load = async id =>
    switch await Ops.jsonOps.load(id->ReadModelSpec.Id.toString) {
    | result =>
      result->Result.map(states => states->Array.map(state => decode(id, state))->Array.flat)
    }

  let save = async (id, state, saveMode, ttl) =>
    switch state->Message.encode(ReadModelSpec.stateSchema)->JSON.Decode.object {
    | Some(dict) =>
      dict->Dict.set("id", id->Message.encode(ReadModelSpec.Id.schema))
      let json = JSON.Encode.object(dict)
      await Ops.jsonOps.save(id->ReadModelSpec.Id.toString, json, saveMode, ttl)
    | None =>
      Console.log2("QueryDB.saveState: Error: Couldn't decodeObject:", state->JSON.stringifyAny)
      Error(ReventlessSpec.QueryDb.NotSavedToStorage("Couldn't decodeObject"))
    }

  let saveBatch = async states => {
    let batch = states->Array.filterMap(((id, state, ttl)) =>
      switch state->Message.encode(ReadModelSpec.stateSchema)->JSON.Decode.object {
      | Some(dict) =>
        dict->Dict.set("id", id->Message.encode(ReadModelSpec.Id.schema))
        let json = JSON.Encode.object(dict)
        Some((id->ReadModelSpec.Id.toString, json, ttl))
      | None =>
        Console.log2("QueryDB.saveStates: Error: Couldn't decodeObject:", state->JSON.stringifyAny)
        None
      }
    )
    await Ops.jsonOps.saveBatch(batch)
  }

  let count = async (id, fieldName, inc) =>
    await Ops.jsonOps.count(id->ReadModelSpec.Id.toString, fieldName, inc)

  let delete = async (id, subId) => await Ops.jsonOps.delete(id->ReadModelSpec.Id.toString, subId)

  let deleteBatch = async ids => {
    let ids = ids->Array.map(((id, sort)) => (id->ReadModelSpec.Id.toString, sort))
    await Ops.jsonOps.deleteBatch(ids)
  }
}
