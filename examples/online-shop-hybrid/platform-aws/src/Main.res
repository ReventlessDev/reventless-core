// Platform deployment — admin components, scheduler, shared AppSync API.
// Deploy this stack first; plugin stacks reference its outputs.

module Platform = ReventlessAws.Platform.Make()

Platform.deployPlatform(~version=Reventless.PackageVersion.fromCaller())

// Re-export collected stack outputs for Pulumi.
// Pulumi reads the default export as stack outputs when it's an object.
let default = Pulumi.Pulumi.getOutputs()
