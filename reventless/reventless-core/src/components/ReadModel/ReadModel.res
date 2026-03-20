let componentType = ComponentType.ReadModel

type t
type outputs = ReventlessInfra.ReadModel.outputs
type operations = ReventlessInfra.ReadModel.operations
type component = Component.t<t, outputs, operations>

module type T = {
  module Spec: Reventless.ReadModel.Spec
  module EventCollectorRuntimeBuilder: EventCollectorRuntime_Builder.T

  type api
  type role
  type component = Component.t<t, outputs, operations>
  let make: (
    ~api: api,
    ~apiRole: role,
    ~allEventTopics: EventTopic.allOutputs,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
  let outputs: component => outputs
  let operations: component => Pulumi.Output.t<operations>
  let finish: unit => unit
}

let toResolvedOutputs = (
  outputs: outputs,
): Pulumi.Output.t<ReventlessInterop.ReadModel.resolvedOutputs> =>
  outputs.queryDb.resources
  ->Adapter.resourcesToInterop
  ->Pulumi.Output.apply(queryDbResources => {
    let resolved: ReventlessInterop.ReadModel.resolvedOutputs = {
      name: outputs.name,
      queryDb: {resources: queryDbResources},
      sourceNames: outputs.sourceNames,
    }
    resolved
  })

let allQueryDbs = allReadModels =>
  Dict.mapValues(allReadModels, (readModel: outputs) => readModel.queryDb)
