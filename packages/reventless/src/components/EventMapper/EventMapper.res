module ReventlessEventCollector = EventCollector

let componentType = ComponentType.EventMapper

type outputs = {
  name: string,
  eventCollector: Pulumi.Output.t<EventCollector.outputs>,
  counter?: Counter.outputs,
}

type t
type component = Component.t<t, outputs, unit>

module type T = {
  let make: (
    ~allEventTopics: EventTopic.allOutputs,
    ~queryEngine: ReventlessSpec.QueryEngine.operations,
    ~publishJsons: CommandTopic.publishJsons,
    ~memorySize: int=?,
    ~timeout: int=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}

module type Mappings = {
  module Target: ReventlessSpec.EventMapping.Target
  module type Mapping = ReventlessSpec.EventMapping.T with module Target := Target
  let mappings: array<module(Mapping)>
  let counter: option<module(Counter.T)>
}
