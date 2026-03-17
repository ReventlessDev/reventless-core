// Ordering plugin deployment — deploys as an independent Pulumi stack.
// Reads platform and catalog stack outputs via StackReference for cross-plugin EP resolution.

module Platform = ReventlessAws.Platform.Make()
module Ordering = OrderingPlugin.OrderingPlugin.Make(Platform)

Platform.deployPlugin(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugin=module(Ordering),
)
