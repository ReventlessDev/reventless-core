module ReventlessEventCollector = EventCollector

let componentType = ComponentType.EventMapper

type outputs = ReventlessInfra.EventMapper.outputs

type t
type component = Component.t<t, outputs, unit>

module type T = {
  let make: (
    ~name: string,
    ~allEventTopics: EventTopic.allOutputs,
    ~queryEngine: Reventless.QueryEngine.operations,
    ~publishJsons: CommandTopic.publishJsons,
    ~resources: array<ReventlessInfra.Adapter.resource>,
    ~memorySize: int=?,
    ~timeout: int=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}

module type Mappings = {
  module Target: Reventless.EventMapping.Target
  module type Mapping = Reventless.EventMapping.T with module Target := Target
  let mappings: array<module(Mapping)>
  let counter: option<module(Counter.T)>
}
