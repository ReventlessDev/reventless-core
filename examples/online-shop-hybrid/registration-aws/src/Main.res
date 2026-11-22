// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
// Registration plugin — AWS deployment.

ReventlessInfra.DeployBootstrap.run(PreDeploy)

module Platform = ReventlessAws.Platform.Make()
module Registration = Plugin.Make(Platform)

let default = ReventlessAws.Platform.loadProvidedGroups()->Promise.thenResolve(() => {
  let deployed = Platform.deployPlugin(~plugin=module(Registration))
  ReventlessInfra.DeployBootstrap.run(PostDeploy)
  deployed
})
