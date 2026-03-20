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

let toResolvedOutputs = (
  outputs: outputs,
): Pulumi.Output.t<ReventlessInterop.EventMapper.resolvedOutputs> => {
  let eventCollectorOutput =
    outputs.eventCollector->Pulumi.Output.flatMap((ec: ReventlessEventCollector.outputs) =>
      ec.resources
      ->Adapter.resourcesToInterop
      ->Pulumi.Output.apply(resources => {
        let resolved: ReventlessInterop.EventCollector.resolvedOutputs = {
          name: ec.name,
          resources: resources,
        }
        resolved
      })
    )
  let counterOutput = switch outputs.counter {
  | Some(counter) =>
    (
      counter.referencesDb.resources->Adapter.resourcesToInterop,
      counter.countsDb.resources->Adapter.resourcesToInterop,
    )
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((referencesDbResources, countsDbResources)) =>
      Some({
        ReventlessInterop.Counter.referencesDb: {resources: referencesDbResources},
        countsDb: {resources: countsDbResources},
      })
    )
  | None => Pulumi.Output.make(None)
  }
  (eventCollectorOutput, counterOutput)
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((eventCollector, counter)) =>
    switch counter {
    | Some(counter) => {
        ReventlessInterop.EventMapper.name: outputs.name,
        eventCollector,
        counter,
      }
    | None => {name: outputs.name, eventCollector}
    }
  )
}

module type Mappings = {
  module Target: Reventless.EventMapping.Target
  module type Mapping = Reventless.EventMapping.T with module Target := Target
  let mappings: array<module(Mapping)>
  let counter: option<module(Counter.T)>
}
