type publisher = {
  resources: array<Reventless.Adapter.resource>,
  publishJson: Pulumi.Output.t<EventTopic.publishJson>,
}

type publisherMaker = (
  ~name: string,
  ~storageResources: array<Reventless.Adapter.resource>,
  ~opts: Pulumi.CustomResourceOptions.t,
) => publisher

module type Publisher = {
  let make: publisherMaker
}
