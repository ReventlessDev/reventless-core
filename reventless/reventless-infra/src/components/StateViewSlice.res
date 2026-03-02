/**
Deploy-time outputs produced when a `StateViewSlice` is provisioned.

- `resources` — the underlying infrastructure (e.g. SQS subscription)
- `queryDb` — the DynamoDB table for querying projected state
*/
type outputs = {
  resources: array<Adapter.resource>,
  queryDb: QueryDb.outputs,
}

/**
Runtime operations exposed by a `StateViewSlice` component.
Used to push events into the slice's projection queue.
*/
type operations = {enqueueEvent: EventCollector.enqueueEvent}

/**
Module type produced by `Platform.StateViewSlice.Make(Spec)`.

@example
```rescript
// CatalogPlugin.res
module CategoriesViewSlice = Platform.StateViewSlice.Make(CategoriesView)
let slice = CategoriesViewSlice.make(~dcbEventLog=log)
```
*/
module type T = {
  /** The DCB event type this slice subscribes to (fixed by `Spec.DcbEventLogSpec.event`). */
  type dcbEvent
  module Spec: Reventless.StateViewSlice.Spec
  type dcbEventLogComponent
  type component
  let make: (
    ~dcbEventLog: dcbEventLogComponent,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
