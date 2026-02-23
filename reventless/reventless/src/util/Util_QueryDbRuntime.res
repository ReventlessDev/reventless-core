let getRuntimeResource = (allQueryDbs: dict<Adapter.unwrappedResource>, queryDbName) =>
  try allQueryDbs->Dict.get(queryDbName)->Option.getOrThrow catch {
  | exn =>
    Console.log2(
      `Util_QueryDbRuntime.getRuntimeResource: Couldn't find QueryDb ${queryDbName} in`,
      allQueryDbs,
    )
    throw(exn)
  }
