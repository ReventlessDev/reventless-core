/**
Deploy-time outputs produced when a `StateChangeSlice` is provisioned.
Contains the underlying command queue infrastructure resources.
*/
type outputs = {
  resources: array<Adapter.resource>,
}

/**
Runtime operations exposed by a `StateChangeSlice` component.
Used to publish commands to this slice's command topic.
*/
type operations = {publishJsons: CommandTopic.publishJsons}

/**
Module type produced by `Platform.StateChangeSlice.Make(Spec)`.

@example
```rescript
// CatalogPlugin.res
module AddCategorySlice = Platform.StateChangeSlice.Make(AddCategory)
let slice = AddCategorySlice.make(~dcbEventLog=log, ~publishJsons=publishJsonsOutput)
```
*/
module type T = {
  /** The DCB event type this slice operates on (fixed by `Spec.DcbEventLogSpec.event`). */
  type dcbEvent
  module Spec: Reventless.StateChangeSlice.Spec
  type dcbEventLogComponent
  type component
  let make: (
    ~dcbEventLog: dcbEventLogComponent,
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
