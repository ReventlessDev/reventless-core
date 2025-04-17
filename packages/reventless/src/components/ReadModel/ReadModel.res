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
  module ReadModelRuntimeBuilder: ReadModelRuntime_Builder.T

  let make: (
    ~allEventTopics: EventTopic.allOutputs,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}

let allQueryDbs = allReadModels =>
  Js.Dict.map((readModel: outputs) => readModel.queryDb, allReadModels)
