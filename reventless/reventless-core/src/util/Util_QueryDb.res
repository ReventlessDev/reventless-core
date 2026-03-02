let getLocalStorageResources = (allQueryDbs: dict<QueryDb.outputs>, queryDbName): array<
  ReventlessInfra.Adapter.resource,
> =>
  try (allQueryDbs->Dict.get(queryDbName)->Option.getOrThrow).resources catch {
  | exn =>
    Console.log2(
      `Util_QueryDbRuntime.getLocalStorageResources: Couldn't find QueryDb ${queryDbName} in`,
      allQueryDbs,
    )
    throw(exn)
  }
