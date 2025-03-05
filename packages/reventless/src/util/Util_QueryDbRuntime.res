let getRuntimeResource = (allQueryDbs: Js.Dict.t<Adapter.unwrappedResource>, queryDbName) =>
  try allQueryDbs->Js.Dict.get(queryDbName)->Belt.Option.getExn catch {
  | exn =>
    Js.log2(
      `Util_QueryDbRuntime.getRuntimeResource: Couldn't find QueryDb ${queryDbName} in`,
      allQueryDbs,
    )
    raise(exn)
  }
