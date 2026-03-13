/**
Deploy-time outputs produced when an `AutomationSlice` is provisioned.

- `resources` — the underlying infrastructure (e.g. SQS subscription)
- `queryDb` — the DynamoDB table for the TODO list
*/
type outputs = {
  resources: array<Adapter.resource>,
  queryDb: QueryDb.outputs,
}

/**
Runtime operations exposed by an `AutomationSlice` component.

- `enqueueEvent` — push events into the slice's projection queue
- `processPending` — manually trigger Phase 2 (useful in tests and for heartbeat)
*/
type operations = {
  enqueueEvent: EventCollector.enqueueEvent,
  processPending: unit => promise<unit>,
}

/**
Module type produced by `Platform.AutomationSlice.Make(Spec)`.

@example
```rescript
module ShipOrderSlice = Platform.AutomationSlice.Make(ShipOrder)
let slice = ShipOrderSlice.make(~dcbEventLog=log, ~publishJsons=publishJsonsOutput)
```
*/
type t

module type T = {
  /** The DCB event type this slice operates on (fixed by `Spec.DcbEventLogSpec.event`). */
  type dcbEvent
  module Spec: Reventless.AutomationSlice.Spec
  type dcbEventLogComponent = DcbEventLog.component<DcbEventLog.operations<dcbEvent>>
  type component = Component.t<t, outputs, operations>
  let queryDbName: string
  let make: (
    ~dcbEventLog: dcbEventLogComponent,
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
