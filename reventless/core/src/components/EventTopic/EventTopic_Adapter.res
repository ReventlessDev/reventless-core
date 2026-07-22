type publisher = {
  resources: array<ReventlessInfra.Adapter.resource>,
  publishJson: Pulumi.Output.t<EventTopic.publishJson>,
  publishJsonStream: Pulumi.Output.t<ReventlessInfra.EventTopic.publishJsonStream>,
}

type publisherMaker = (
  ~name: string,
  ~storageResources: array<ReventlessInfra.Adapter.resource>,
  ~owner: option<ResourceAttribution.owner>,
  ~opts: Pulumi.CustomResourceOptions.t,
) => publisher

module type Publisher = {
  let make: publisherMaker
}
