module type T = {
  let name: string

  module DcbEventLogSpec: DcbEventLog_Spec.T

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
