let log = Logger.fromEnv()

let getLocalStorageResources = (allQueryDbs: dict<QueryDb.outputs>, queryDbName): array<
  ReventlessInfra.Adapter.resource,
> =>
  try (allQueryDbs->Dict.get(queryDbName)->Option.getOrThrow).resources catch {
  | exn =>
    log.error(
      ~comp="Util_QueryDb",
      ~data=allQueryDbs->JSON.stringifyAny->Option.getOr("")->JSON.Encode.string,
      `getLocalStorageResources: Couldn't find QueryDb ${queryDbName}`,
    )
    throw(exn)
  }
