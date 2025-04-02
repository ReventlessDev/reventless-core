let getRuntimeResource = (allQueryDbs: dict<Adapter.unwrappedResource>, queryDbName) =>
  try allQueryDbs->Js.Dict.get(queryDbName)->Option.getExn catch {
  | exn =>
    Js.log2(
      `Util_QueryDbRuntime.getRuntimeResource: Couldn't find QueryDb ${queryDbName} in`,
      allQueryDbs,
    )
    raise(exn)
  }
