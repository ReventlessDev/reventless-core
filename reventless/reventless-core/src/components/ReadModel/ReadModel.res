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

let allQueryDbs = allReadModels =>
  Dict.mapValues(allReadModels, (readModel: outputs) => readModel.queryDb)
