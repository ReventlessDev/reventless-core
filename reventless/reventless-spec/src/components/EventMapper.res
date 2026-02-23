type outputs = {
  name: string,
  eventCollector: Pulumi.Output.t<EventCollector.outputs>,
  counter?: Counter.outputs,
}

module type Mappings = {
  module Target: EventMapping.Target
  module type Mapping = EventMapping.T with module Target := Target
  let mappings: array<module(Mapping)>
  let counter: option<module(Counter.T)>
}
