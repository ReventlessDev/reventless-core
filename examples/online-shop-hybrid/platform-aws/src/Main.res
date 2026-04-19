// Platform deployment — admin components, scheduler, shared AppSync API.
// Deploy this stack first; plugin stacks reference its outputs.

module Platform = ReventlessAws.Platform.Make()

let default = Platform.deployPlatform(~version=Reventless.PackageVersion.fromCaller())
