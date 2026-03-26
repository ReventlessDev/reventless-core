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

type t

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
  module Spec: Reventless.StateViewSlice.Spec
  type component = Component.t<t, outputs, operations>
  let make: (
    ~dcbEventLog: DcbEventLog.component,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
