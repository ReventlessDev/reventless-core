let componentType = ComponentType.CommandHandler

type t
type outputs = {
  resources: array<ReventlessSpec.Adapter.resource>,
  commandTopic: Pulumi.Output.t<CommandTopic.outputs>,
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

  let queryEventTypes: array<string>
}

module type T = {
  type dcbEvent
  module Spec: Spec

  let make: (
    ~dcbEventLog: DcbEventLog.component<DcbEventLog.operations<dcbEvent>>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
