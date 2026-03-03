/**
Deploy-time outputs produced when an `OutboundTranslationSlice` is provisioned.

- `resources` -- the underlying infrastructure (e.g. SQS subscription)
- `queryDb` -- the DynamoDB table for the TODO list
*/
type outputs = {
  resources: array<Adapter.resource>,
  queryDb: QueryDb.outputs,
}

/**
Runtime operations exposed by an `OutboundTranslationSlice` component.

- `enqueueEvent` -- push events into the slice's projection queue
- `translatePending` -- manually trigger Phase 2 (useful in tests and for heartbeat)
*/
type operations = {
  enqueueEvent: EventCollector.enqueueEvent,
  translatePending: unit => promise<unit>,
}

/**
Module type produced by `Platform.OutboundTranslationSlice.Make(Spec)`.

@example
```rescript
module SendTrackingEmailSlice = Platform.OutboundTranslationSlice.Make(SendTrackingEmail)
let slice = SendTrackingEmailSlice.make(~dcbEventLog=log, ~publishJsons=publishJsonsOutput)
```
*/
module type T = {
  /** The DCB event type this slice operates on (fixed by `Spec.DcbEventLogSpec.event`). */
  type dcbEvent
  module Spec: Reventless.OutboundTranslationSlice.Spec
  type dcbEventLogComponent
  type component
  let make: (
    ~dcbEventLog: dcbEventLogComponent,
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
