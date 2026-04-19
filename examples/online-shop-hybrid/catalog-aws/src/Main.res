// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
// Catalog plugin — AWS deployment.

module Platform = ReventlessAws.Platform.Make()
module Catalog = Plugin.Make(Platform)

let default = Platform.deployPlugin(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~plugin=module(Catalog),
)
