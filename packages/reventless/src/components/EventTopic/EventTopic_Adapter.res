type publisher = {
  resources: array<ReventlessSpec.Adapter.resource>,
  publishJson: Pulumi.Output.t<EventTopic.publishJson>,
}

type publisherMaker = (
  ~name: string,
  ~storageResources: array<ReventlessSpec.Adapter.resource>,
  ~opts: Pulumi.CustomResourceOptions.t,
) => publisher

module type Publisher = {
  let make: publisherMaker
}
