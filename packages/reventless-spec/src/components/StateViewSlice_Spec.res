module type T = {
  let name: string

  module DcbEventLogSpec: DcbEventLog_Spec.T

  @schema
  type event

  @schema
  type state

  let project: (
    option<state>,
    DcbEventLogSpec.event,
  ) => array<Projection_Spec.action<string, state>>
}
