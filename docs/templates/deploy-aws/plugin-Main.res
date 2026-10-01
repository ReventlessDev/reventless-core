// {{PLUGIN_NAME}} plugin deployment — deploys as an independent Pulumi stack.
// Reads platform stack outputs via StackReference (configured in Pulumi.<env>.yaml).

module Platform = ReventlessAws.Platform.Make()
module {{PLUGIN_NAME}} = {{PLUGIN_MODULE}}.Make(Platform)

// Deployed once the user pool's groups are in, for the check that every role the
// plugin needs has one. Not a top-level await: Pulumi `require`s the program.
let default = ReventlessAws.Platform.loadProvidedGroups()->Promise.thenResolve(() =>
  Platform.deployPlugin(
    ~version=Reventless.PackageVersion.fromCaller(),
    ~plugin=module({{PLUGIN_NAME}}),
  )
)
