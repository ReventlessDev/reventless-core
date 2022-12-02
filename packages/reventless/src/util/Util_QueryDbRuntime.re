let getLocalStorageResources =
    (allQueryDbs, queryDbName): array(ReventlessSpec.Adapter.resource) =>
  try (
    {
      allQueryDbs
      ->Js.Dict.entries
      ->Belt.Array.forEach(((name, queryDb)) =>
          queryDb##resources
          ->Belt.Array.map(resource =>
              try (resource##service->Pulumi.Output.apply(_ => ())) {
              | _ =>
                Js.log3(
                  "Util_QueryDbRuntime.getLocalStorageResources: no Output !",
                  name,
                  resource##service,
                )
                ->Pulumi.Output.make
              }
            )
          ->ignore
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
