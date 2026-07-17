let getRuntimeResource = (allQueryDbs: dict<Adapter.resolvedResource>, queryDbName) =>
  try allQueryDbs->Dict.get(queryDbName)->Option.getOrThrow catch {
  | exn =>
    EffectLogger.logError(
      ~comp=__MODULE__,
      `getRuntimeResource: Couldn't find QueryDb ${queryDbName} in ${allQueryDbs
        ->Dict.keysToArray
        ->Array.joinUnsafe(", ")}`,
    )->Effect.runSync
    throw(exn)
  }
