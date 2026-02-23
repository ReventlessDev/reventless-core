type resource = {
  name: Pulumi.Output.t<string>,
  id: Pulumi.Output.t<string>,
  urn: Pulumi.Output.t<string>,
  info: Pulumi.Output.t<string>,
  service: Pulumi.Output.t<string>,
}

type resources = dict<resource>

type unwrappedResource = {
  name: string,
  id: string,
  urn: string,
  info: string,
  service: string,
}
