let log = Logger.fromEnv()

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

  // Every union value in the row carries the GraphQL member type it is, written
  // once here rather than by each of the fourteen read doors across three
  // backends — and, unlike a read-time stamp, it is also on the row the live
  // change channel hands over as raw JSON. A view with no union field is walked
  // and left exactly as it was.
  // The union fields this view declares, read once. Empty for most views, and
  // the whole diagnostic below costs nothing when it is.
  let declaredUnionFields =
    Reventless.TaggedUnion.fieldsOf(ReadModelSpec.stateSchema->S.castToUnknown)

  // Logged once per instantiation, and unconditionally: "none" has to be
  // distinguishable from "never instantiated", because a schema that resolves no
  // union fields and a stamp that failed to run leave the same stored row.
  log.debug(
    ~comp="QueryDb",
    `${ReadModelSpec.name}: union fields ${switch declaredUnionFields {
      | [] => "none"
      | fields =>
        fields->Array.map(((f, n)) => `${f}:${n->Option.getOr("<unnamed>")}`)->Array.join(", ")
      }}`,
  )

  // A union value stored without `__typename` is the failure D1 exists to
  // prevent, and it is silent: the member resolves to null, the null takes its
  // non-nullable parent, and a list loses the row rather than erroring. Nothing
  // downstream can tell that from "no such row", so it is reported here — the
  // one place that knows both the schema and the row.
  let reportUnstamped = dict =>
    declaredUnionFields->Array.forEach(((field, unionName)) =>
      switch dict->Dict.get(field)->Option.flatMap(JSON.Decode.object) {
      | Some(value) if value->Dict.get("TAG")->Option.isSome =>
        if value->Dict.get(Reventless.TaggedUnion.typenameKey)->Option.isNone {
          log.warn(
            ~comp="QueryDb",
            `${ReadModelSpec.name}.${field}: stored a union value with no ${Reventless.TaggedUnion.typenameKey} ` ++
            `(union ${unionName->Option.getOr("<unnamed>")}). The field will resolve to null and take its ` ++
            `parent with it. Union fields seen on this spec: ${declaredUnionFields
              ->Array.map(((f, _)) => f)
              ->Array.join(", ")}`,
          )
        }
      | _ => ()
      }
    )

  let stampUnionMembers = dict => {
    Reventless.TaggedUnion.stampInto(
      ~schema=ReadModelSpec.stateSchema->S.castToUnknown,
      JSON.Encode.object(dict),
    )
    reportUnstamped(dict)
  }

  let save = async (id, state, saveMode, ttl) =>
    switch state->Message.encode(ReadModelSpec.stateSchema)->JSON.Decode.object {
    | Some(dict) =>
      dict->Dict.set("id", id->Message.encode(ReadModelSpec.Id.schema))
      injectSubId(dict, state)
      injectCompositeIndexAttrs(dict)
      stampUnionMembers(dict)
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
          stampUnionMembers(dict)
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
