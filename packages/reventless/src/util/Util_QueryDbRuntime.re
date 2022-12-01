let getLocalStorageResources =
    (allQueryDbs, queryDbName): array(ReventlessSpec.Adapter.resource) =>
  try (
    {
      Js.log2(
        "Util_queryDbRuntime.getLocalStorageResources: allQueryDbs:",
        allQueryDbs,
      );
      allQueryDbs->Js.Dict.get(queryDbName)->Belt.Option.getExn##resources;
    }
  ) {
  | exn =>
    Js.log2(
      {j|Util_QueryDbRuntime.getLocalStorageResources: Couldn't find QueryDb $queryDbName in|j},
      allQueryDbs,
    );
    raise(exn);
  };
