type registerResource = (. Pulumi.Resource.t) => unit

let getDependencies: unit => (Pulumi.Output.t<array<Pulumi.Resource.t>>, registerResource)
