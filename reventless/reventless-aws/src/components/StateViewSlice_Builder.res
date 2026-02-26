// StateViewSlice_Builder (AWS) — placeholder pending AWS adapter implementation.
// TODO: wire AWS adapters (DynamoDB Streams / Lambda / SNS) once designed.
//
// For now produces a no-op component that satisfies the type but does nothing at runtime.

module Make = (Spec: Reventless.StateViewSlice.Spec): (
  ReventlessCore.StateViewSlice.T with type dcbEvent = Spec.DcbEventLogSpec.event and module Spec = Spec
) => {
  type dcbEvent = Spec.DcbEventLogSpec.event
  module Spec = Spec
  type dcbEventLogComponent = ReventlessCore.DcbEventLog.component<
    ReventlessCore.DcbEventLog.operations<dcbEvent>,
  >
  type component = ReventlessCore.StateViewSlice.component

  let make = (~dcbEventLog, ~opts=?): component =>
    ReventlessCore.Component.make(
      ~componentType=ReventlessCore.StateViewSlice.componentType->ReventlessCore.ComponentType.toString,
      ~name=Spec.name,
      ~construct=(self, _name) => {
        let dcbOutputs: ReventlessCore.DcbEventLog.outputs = dcbEventLog->ReventlessCore.Component.outputs
        let outputs: ReventlessCore.StateViewSlice.outputs = {
          resources: dcbOutputs.resources,
          queryDb: {resources: [], resolversMaker: _ => []},
        }
        self->ReventlessCore.Component.setOutputs(outputs)
      },
      ~opts,
    )
}
