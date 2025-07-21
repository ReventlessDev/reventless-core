let getLocalStorageResources = (allQueryDbs: dict<QueryDb.outputs>, queryDbName): array<
  ReventlessSpec.Adapter.resource,
> =>
  try (allQueryDbs->Js.Dict.get(queryDbName)->Option.getExn).resources catch {
  | exn =>
    Js.log2(
      `Util_QueryDbRuntime.getLocalStorageResources: Couldn't find QueryDb ${queryDbName} in`,
      allQueryDbs,
    )
    raise(exn)
  }
