module Make = (Spec: StateViewSlice.Spec): (
  StateViewSlice.T with type dcbEvent = Spec.DcbEventLogSpec.event and module Spec = Spec
) => {
  type dcbEvent = Spec.DcbEventLogSpec.event
  module Spec = Spec

  let construct = (
    ~dcbEventLog: DcbEventLog.component<DcbEventLog.operations<dcbEvent>>,
    self,
    _name,
  ) => {
    // The actual QueryDb and EventCollector creation happens in Plugin_Builder
    // This is just a placeholder that sets up basic outputs

    self->Component.setOutputs({
      StateViewSlice.resources: (dcbEventLog->Component.outputs).resources,
      StateViewSlice.queryDb: {
        resources: [],
        resolversMaker: _ => [],
      },
    })
  }

  let make = (~dcbEventLog, ~opts=?): StateViewSlice.component =>
    Component.make(
      ~componentType=StateViewSlice.componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~dcbEventLog, ...),
      ~opts,
    )
}
