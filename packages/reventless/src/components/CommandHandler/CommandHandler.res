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

  module DcbEventLog: DcbEventLog.Spec

  @schema
  type command

  @schema
  type error

  type decisionModel
  let initialDecisionModel: decisionModel

  let reduce: (decisionModel, DcbEventLog.event) => decisionModel

  let decide: (decisionModel, command) => result<array<DcbEventLog.event>, error>

  let queryEventTypes: array<string>
}

module type T = {
  module Spec: Spec
  module DcbEventLogModule: DcbEventLog.T with module Spec = Spec.DcbEventLog

  let make: (
    ~dcbEventLog: DcbEventLogModule.component,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
