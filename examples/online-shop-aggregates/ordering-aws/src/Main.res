// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
// Ordering plugin — AWS deployment.

ReventlessInfra.DeployBootstrap.run(PreDeploy)

module Platform = ReventlessAws.Platform.Make()
module Ordering = Plugin.Make(Platform)

let default = ReventlessAws.Platform.loadProvidedGroups()->Promise.thenResolve(() => {
  let deployed = Platform.deployPlugin(~plugin=module(Ordering))
  ReventlessInfra.DeployBootstrap.run(PostDeploy)
  deployed
})
