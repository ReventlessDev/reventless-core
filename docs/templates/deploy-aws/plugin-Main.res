// {{PLUGIN_NAME}} plugin deployment — deploys as an independent Pulumi stack.
// Reads platform stack outputs via StackReference (configured in Pulumi.<env>.yaml).

module Platform = ReventlessAws.Platform.Make()
module {{PLUGIN_NAME}} = {{PLUGIN_MODULE}}.Make(Platform)

Platform.deployPlugin(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugin=module({{PLUGIN_NAME}}),
)
