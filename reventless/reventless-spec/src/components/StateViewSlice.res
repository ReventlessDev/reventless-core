module type Spec = {
  let name: string

  module DcbEventLogSpec: DcbEventLog.Spec

  @schema
  type event

  @schema
  type state

  let project: (option<state>, DcbEventLogSpec.event) => array<Projection.action<string, state>>
}

type outputs = {
  resources: array<Adapter.resource>,
  queryDb: QueryDb.outputs,
}
type operations = {enqueueEvent: EventCollector.enqueueEvent}

module type T = {
  type dcbEvent
  module Spec: Spec
  type dcbEventLogComponent
  type component
  let make: (
    ~dcbEventLog: dcbEventLogComponent,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
