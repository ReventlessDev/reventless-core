let componentType = ComponentType.StateChangeSlice

type t
type outputs = {
  resources: array<ReventlessSpec.Adapter.resource>,
}
type operations = {publishJsons: CommandTopic.publishJsons}
type component = Component.t<t, outputs, operations>

module type Spec = {
  let name: string

  module DcbEventLogSpec: DcbEventLog.Spec

  @schema
  type command

  @schema
  type error

  type decisionModel
  let initialDecisionModel: decisionModel

  let reduce: (decisionModel, DcbEventLogSpec.event) => decisionModel
  let decide: (decisionModel, command) => result<array<DcbEventLogSpec.event>, error>

  // Schema for the command type - used for schema-based filtering
  let commandSchema: S.t<command>
}

module type T = {
  type dcbEvent
  module Spec: Spec

  let make: (
    ~dcbEventLog: DcbEventLog.component<DcbEventLog.operations<dcbEvent>>,
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
