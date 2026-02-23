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

type outputs = {
  resources: array<Adapter.resource>,
}
type operations = {publishJsons: CommandTopic.publishJsons}

module type T = {
  type dcbEvent
  module Spec: Spec
  type dcbEventLogComponent
  type component
  let make: (
    ~dcbEventLog: dcbEventLogComponent,
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
