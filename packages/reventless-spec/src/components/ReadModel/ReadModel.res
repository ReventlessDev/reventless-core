module Spec = ReadModel_Spec

type t
type outputs = {
  "name": string,
  "queryDb": QueryDb.outputs,
  "eventCollector": EventCollector.outputs,
}
type component = Component.t<t, outputs>

module type T = {
  module Spec: Spec.T
  type t

  let make: (
    ~allEventTopics: EventTopic.allOutputs,
    ~opts: Pulumi.ComponentResource.options=?,
    unit,
  ) => Component.t<t, outputs>

  let enqueueEvent: component => EventCollector.enqueueEvent

  let sourceNames: array<string>
}
