// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
// Catalog plugin — AWS deployment.

ReventlessInfra.DeployBootstrap.run(PreDeploy)

module Platform = ReventlessAws.Platform.Make()
module Catalog = Plugin.Make(Platform)

let default = Platform.deployPlugin(
  ~plugin=module(Catalog),
)

ReventlessInfra.DeployBootstrap.run(PostDeploy)
