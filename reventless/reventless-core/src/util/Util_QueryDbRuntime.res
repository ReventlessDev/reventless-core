let getRuntimeResource = (allQueryDbs: dict<Adapter.resolvedResource>, queryDbName) =>
  try allQueryDbs->Dict.get(queryDbName)->Option.getOrThrow catch {
  | exn =>
    Effect.logError(
      `Util_QueryDbRuntime.getRuntimeResource: Couldn't find QueryDb ${queryDbName} in ${allQueryDbs
        ->Dict.keysToArray
        ->Array.joinUnsafe(", ")}`,
    )->Effect.runSync
    throw(exn)
  }
