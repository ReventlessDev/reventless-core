type channel = {
  resources: array<ReventlessSpec.Adapter.resource>,
  enqueueEvent: Pulumi.Output.t<EventCollector.enqueueEvent>,
}

type channelMaker = (
  ~name: string,
  ~eventTopics: EventTopic.allOutputs,
  ~handleEvents: EventCollector.eventsHandler,
  ~memorySize: int,
  ~timeout: int,
  ~policy1: Pulumi.Output.t<option<string>>,
  ~policy2: Pulumi.Output.t<option<string>>,
  ~opts: Pulumi.CustomResourceOptions.t,
) => channel

module type Channel = {
  let make: channelMaker
}
