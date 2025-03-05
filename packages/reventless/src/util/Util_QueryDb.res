let getLocalStorageResources = (allQueryDbs: Js.Dict.t<QueryDb.outputs>, queryDbName): array<
  ReventlessSpec.Adapter.resource,
> =>
  try (allQueryDbs->Js.Dict.get(queryDbName)->Belt.Option.getExn).resources catch {
  | exn =>
    Js.log2(
      `Util_QueryDbRuntime.getLocalStorageResources: Couldn't find QueryDb ${queryDbName} in`,
      allQueryDbs,
    )
    raise(exn)
  }
