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
        Reventless.QueryDb.NotLoadedFromStorage(
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

  let save = async (id, state, saveMode, ttl) =>
    switch state->Message.encode(ReadModelSpec.stateSchema)->JSON.Decode.object {
    | Some(dict) =>
      dict->Dict.set("id", id->Message.encode(ReadModelSpec.Id.schema))
      let json = JSON.Encode.object(dict)
      await Ops.jsonOps.save(id->ReadModelSpec.Id.toString, json, saveMode, ttl)
    | None =>
      Error(Reventless.QueryDb.NotSavedToStorage("Couldn't encode state as JSON object"))
    }

  let saveBatch = async states => {
    let batchResult = states->Array.reduce(Ok([]), (acc, (id, state, ttl)) =>
      acc->Result.flatMap(batch =>
        switch state->Message.encode(ReadModelSpec.stateSchema)->JSON.Decode.object {
        | Some(dict) =>
          dict->Dict.set("id", id->Message.encode(ReadModelSpec.Id.schema))
          let json = JSON.Encode.object(dict)
          Ok(batch->Array.concat([(id->ReadModelSpec.Id.toString, json, ttl)]))
        | None =>
          Error(
            Reventless.QueryDb.NotSavedToStorage(
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
