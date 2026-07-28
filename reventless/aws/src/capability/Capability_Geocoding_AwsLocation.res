// A geocoding place index, provisioned with the framework's house conventions
// applied — the address-search backing for geo-point command inputs.
//
// Beyond the attribution tags every framework resource carries, this helper
// exists to move two settings out of application code. `dataSource` picks the
// geospatial data provider and `intendedUse` decides whether results may be
// stored; between them they determine the licensing terms, the per-request
// price, and how long returned data may be retained. Those are deployment
// decisions — a change of provider can be a contractual matter — so they read
// from deploy-time config the way the host-shell's custom domain does, rather
// than being literals in an app's `Main.res`.
//
// Config keys (env var `REVENTLESS_<SCREAMING_SNAKE>` → `Pulumi.local.yaml`,
// see `Util_LocalConfig`):
//   - `geocoderDataSource`  — "Esri" | "Grab" | "Here". Default "Esri".
//   - `geocoderIntendedUse` — "SingleUse" | "Storage". Default "SingleUse".
//
// The defaults reproduce what deployments wrote by hand, so adopting this
// helper is not a licensing-tier change.

open PulumiAws

let defaultDataSource = "Esri"
let defaultIntendedUse = "SingleUse"

/** Create a place index with framework attribution tags and config-driven
    provider/retention settings. */
let make = (~name: string, ~opts: option<Pulumi.CustomResourceOptions.t>=?): ReventlessInfra.Platform.geocoderIndex => {
  let dataSource = Util_LocalConfig.get("geocoderDataSource")->Option.getOr(defaultDataSource)
  let intendedUse = Util_LocalConfig.get("geocoderIntendedUse")->Option.getOr(defaultIntendedUse)

  let index = Location.PlaceIndex.make(
    ~name,
    ~args={
      indexName: Pulumi.Input.make(name),
      dataSource: Pulumi.Input.make(dataSource),
      dataSourceConfiguration: Pulumi.Input.make({
        Location.PlaceIndex.intendedUse: Pulumi.Input.make(intendedUse),
      }),
      tags: AWS.Tags.make(
        ~name,
        ~kind=ReventlessCore.ComponentType.Platform,
        ~role=Other("Geocoder"),
        ~scope=Platform,
      ),
    },
    ~opts?,
  )

  {indexName: index.indexName->Pulumi.Output.asInput}
}
