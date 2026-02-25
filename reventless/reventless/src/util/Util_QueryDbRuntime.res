let getRuntimeResource = (allQueryDbs: dict<Adapter.resolvedResource>, queryDbName) =>
  try allQueryDbs->Dict.get(queryDbName)->Option.getOrThrow catch {
  | exn =>
    Console.log2(
      `Util_QueryDbRuntime.getRuntimeResource: Couldn't find QueryDb ${queryDbName} in`,
      allQueryDbs,
    )
    throw(exn)
  }
