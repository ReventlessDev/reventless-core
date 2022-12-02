let getLocalStorageResources =
    (allQueryDbs, queryDbName): array(ReventlessSpec.Adapter.resource) =>
  try (
    {
      Js.log("Util_QueryDbRuntime.getLocalStorageResources.allQueryDbs:");
      let _ =
        allQueryDbs
        ->Js.Dict.entries
        ->Belt.Array.forEach(((name, queryDb)) => {
            Js.log(name ++ ": ------------");
            queryDb##resources
            ->Belt.Array.forEach(resource => Js.log(resource));
          });

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
