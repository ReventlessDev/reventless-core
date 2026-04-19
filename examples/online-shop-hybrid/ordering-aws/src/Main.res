// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
// Ordering plugin — AWS deployment.

module Platform = ReventlessAws.Platform.Make()
module Ordering = Plugin.Make(Platform)

let default = Platform.deployPlugin(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~plugin=module(Ordering),
)
