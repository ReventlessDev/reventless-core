let componentType = ComponentType.StateViewSlice

type t
type outputs = {
  resources: array<ReventlessSpec.Adapter.resource>,
  queryDb: QueryDb.outputs,
}
type operations = {enqueueEvent: EventCollector.enqueueEvent}
type component = Component.t<t, outputs, operations>

module type Spec = {
  let name: string

  module DcbEventLogSpec: DcbEventLog.Spec

  @schema
  type event

  @schema
  type state

  let project: (
    option<state>,
    DcbEventLogSpec.event,
  ) => array<ReventlessSpec.Projection.Spec.action<string, state>>
}

module type T = {
  type dcbEvent
  module Spec: Spec

  let make: (
    ~dcbEventLog: DcbEventLog.component<DcbEventLog.operations<dcbEvent>>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
