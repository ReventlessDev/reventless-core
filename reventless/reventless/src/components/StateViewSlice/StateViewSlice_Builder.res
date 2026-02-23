module Make = (Spec: ReventlessSpec.StateViewSlice.Spec): (
  StateViewSlice.T with type dcbEvent = Spec.DcbEventLogSpec.event and module Spec = Spec
) => {
  type dcbEvent = Spec.DcbEventLogSpec.event
  module Spec = Spec
  type dcbEventLogComponent = DcbEventLog.component<DcbEventLog.operations<dcbEvent>>
  type component = StateViewSlice.component

  let construct = (
    ~dcbEventLog: DcbEventLog.component<DcbEventLog.operations<dcbEvent>>,
    self,
    _name,
  ) => {
    // The actual QueryDb and EventCollector creation happens in Plugin_Builder
    // This is just a placeholder that sets up basic outputs

    let outputs: StateViewSlice.outputs = {
      resources: (dcbEventLog->Component.outputs).resources,
      queryDb: {
        resources: [],
        resolversMaker: _ => [],
      },
    }
    self->Component.setOutputs(outputs)
  }

  let make = (~dcbEventLog, ~opts=?): StateViewSlice.component =>
    Component.make(
      ~componentType=StateViewSlice.componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~dcbEventLog, ...),
      ~opts,
    )
}
