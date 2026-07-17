module type Ops = {
  let jsonOps: QueryDb.operations<string, JSON.t>
}

module Make = (ReadModelSpec: Reventless.ReadModel.Spec, Ops: Ops) => {
  // Returns result<state, storageError> — decode errors are surfaced rather than silently dropped.
  let decode = (id, stateJson) =>
    switch stateJson->Message.decode(ReadModelSpec.stateSchema) {
    | state => Ok(state)
    | exception err =>
      let errStr = err->JSON.stringifyAny->Option.getOr("unknown error")
      Error(
        ReventlessInfra.QueryDb.NotLoadedFromStorage(
          `QueryDb: Error: Couldn't decode state for ${id->ReadModelSpec.Id.toString}: ${errStr}`,
        ),
      )
    }

  let loadStream = id =>
    Ops.jsonOps.loadStream(id->ReadModelSpec.Id.toString)
    ->Stream.mapEffect(json =>
      switch decode(id, json) {
      | Ok(s) => Effect.succeed(s)
      | Error(e) => Effect.fail(e)
      }
    )

  let load = async id =>
    switch await Ops.jsonOps.load(id->ReadModelSpec.Id.toString) {
    | result =>
      result->Result.flatMap(states =>
        states->Array.reduce(Ok([]), (acc, state) =>
          acc->Result.flatMap(arr =>
            decode(id, state)->Result.map(s => arr->Array.concat([s]))
          )
        )
      )
    }

  let injectSubId = (dict, state) =>
    switch ReadModelSpec.subIdConfig {
    | Some({subIdField, getSubId}) =>
      dict->Dict.set(subIdField, JSON.Encode.string(getSubId(state)))
    | None => ()
    }

  let injectCompositeIndexAttrs = dict => {
    let getStr = field =>
      dict->Dict.get(field)->Option.flatMap(JSON.Decode.string)->Option.getOr("")
    ReadModelSpec.config.indexes->Array.forEach(idx => {
      switch idx.pkFields {
      | Some(fs) when fs->Array.length > 1 =>
        let sep = idx.pkSep->Option.getOr("/")
        let value = fs->Array.map(getStr)->Array.join(sep)
        let attrName = idx.idField->Option.getOr("_pk")
        dict->Dict.set(attrName, JSON.Encode.string(value))
      | _ => ()
      }
      switch idx.skFields {
      | Some(fs) when fs->Array.length > 1 =>
        let sep = idx.skSep->Option.getOr("/")
        let value = fs->Array.map(getStr)->Array.join(sep)
        let attrName = idx.subIdField->Option.getOr("_sk")
        dict->Dict.set(attrName, JSON.Encode.string(value))
      | _ => ()
      }
    })
  }

  let save = async (id, state, saveMode, ttl) =>
    switch state->Message.encode(ReadModelSpec.stateSchema)->JSON.Decode.object {
    | Some(dict) =>
      dict->Dict.set("id", id->Message.encode(ReadModelSpec.Id.schema))
      injectSubId(dict, state)
      injectCompositeIndexAttrs(dict)
      let json = JSON.Encode.object(dict)
      await Ops.jsonOps.save(id->ReadModelSpec.Id.toString, json, saveMode, ttl)
    | None =>
      Error(ReventlessInfra.QueryDb.NotSavedToStorage("Couldn't encode state as JSON object"))
    }

  let saveBatch = async states => {
    let batchResult = states->Array.reduce(Ok([]), (acc, (id, state, ttl)) =>
      acc->Result.flatMap(batch =>
        switch state->Message.encode(ReadModelSpec.stateSchema)->JSON.Decode.object {
        | Some(dict) =>
          dict->Dict.set("id", id->Message.encode(ReadModelSpec.Id.schema))
          injectSubId(dict, state)
          injectCompositeIndexAttrs(dict)
          let json = JSON.Encode.object(dict)
          Ok(batch->Array.concat([(id->ReadModelSpec.Id.toString, json, ttl)]))
        | None =>
          Error(
            ReventlessInfra.QueryDb.NotSavedToStorage(
              `Couldn't encode state for ${id->ReadModelSpec.Id.toString}`,
            ),
          )
        }
      )
    )
    switch batchResult {
    | Ok(batch) => await Ops.jsonOps.saveBatch(batch)
    | Error(e) => Error(e)
    }
  }

  let count = async (id, fieldName, inc) =>
    await Ops.jsonOps.count(id->ReadModelSpec.Id.toString, fieldName, inc)

  let delete = async (id, subId) => await Ops.jsonOps.delete(id->ReadModelSpec.Id.toString, subId)

  let deleteBatch = async ids => {
    let ids = ids->Array.map(((id, sort)) => (id->ReadModelSpec.Id.toString, sort))
    await Ops.jsonOps.deleteBatch(ids)
  }
}
