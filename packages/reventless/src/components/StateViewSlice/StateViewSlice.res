let componentType = ComponentType.StateViewSlice

type t
type outputs = {
  resources: array<ReventlessSpec.Adapter.resource>,
  queryDb: QueryDb.outputs,
}
type operations = {enqueueEvent: EventCollector.enqueueEvent}
type component = Component.t<t, outputs, operations>

module type T = {
  type dcbEvent
  module Spec: ReventlessSpec.StateViewSlice_Spec.T

  let make: (
    ~dcbEventLog: DcbEventLog.component<DcbEventLog.operations<dcbEvent>>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
