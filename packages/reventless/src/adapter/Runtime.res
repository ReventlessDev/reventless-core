type environment = {resources: array<ReventlessSpec.Adapter.resource>}
type environmentMaker = (
  ~name: string,
  ~channelResources: array<ReventlessSpec.Adapter.resource>,
  ~handleJsons: CommandTopic.commandsHandler<Js.Json.t>,
  ~opts: Pulumi.CustomResourceOptions.t,
) => environment

module type Environment = {
  let make: environmentMaker
}
