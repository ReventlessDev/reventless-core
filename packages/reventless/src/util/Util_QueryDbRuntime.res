let getLocalStorageResources = (allQueryDbs, queryDbName): array<ReventlessSpec.Adapter.resource> =>
  try (allQueryDbs->Js.Dict.get(queryDbName)->Belt.Option.getExn)["resources"] catch {
  | exn =>
    Js.log2(
      j`Util_QueryDbRuntime.getLocalStorageResources: Couldn't find QueryDb $queryDbName in`,
      allQueryDbs,
    )
    raise(exn)
  }
