let componentType = ComponentType.ReadModel

type t
type outputs = {
  name: string,
  queryDb: QueryDb.outputs,
  eventCollector: Pulumi.Output.t<EventCollector.outputs>,
  sourceNames: array<string>,
}
type operations = {enqueueEvent: EventCollector.enqueueEvent}
type component = Component.t<t, outputs, operations>

module type T = {
  module Spec: ReventlessSpec.ReadModel_Spec.T
  module EventCollectorRuntimeBuilder: EventCollectorRuntime_Builder.T

  type api
  type role
  let make: (
    ~api: api,
    ~apiRole: role,
    ~allEventTopics: EventTopic.allOutputs,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}

let allQueryDbs = allReadModels =>
  Dict.mapValues(allReadModels, (readModel: outputs) => readModel.queryDb)
