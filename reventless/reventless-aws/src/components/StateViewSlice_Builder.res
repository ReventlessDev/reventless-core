// StateViewSlice_Builder (AWS) — placeholder pending AWS adapter implementation.
// TODO: wire AWS adapters (DynamoDB Streams / Lambda / SNS) once designed.
//
// For now produces a no-op component that satisfies the type but does nothing at runtime.

module Make = (Spec: ReventlessSpec.StateViewSlice.Spec): (
  Reventless.StateViewSlice.T with type dcbEvent = Spec.DcbEventLogSpec.event and module Spec = Spec
) => {
  type dcbEvent = Spec.DcbEventLogSpec.event
  module Spec = Spec
  type dcbEventLogComponent = Reventless.DcbEventLog.component<
    Reventless.DcbEventLog.operations<dcbEvent>,
  >
  type component = Reventless.StateViewSlice.component

  let make = (~dcbEventLog, ~opts=?): component =>
    Reventless.Component.make(
      ~componentType=Reventless.StateViewSlice.componentType->Reventless.ComponentType.toString,
      ~name=Spec.name,
      ~construct=(self, _name) => {
        let dcbOutputs: Reventless.DcbEventLog.outputs = dcbEventLog->Reventless.Component.outputs
        let outputs: Reventless.StateViewSlice.outputs = {
          resources: dcbOutputs.resources,
          queryDb: {resources: [], resolversMaker: _ => []},
        }
        self->Reventless.Component.setOutputs(outputs)
      },
      ~opts,
    )
}
