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

type t

/**
Module type produced by `Platform.StateChangeSlice.Make(Spec, Behavior)`.

@example
```rescript
// CatalogPlugin.res
module AddCategorySlice = Platform.StateChangeSlice.Make(AddCategory, AddCategory_Behavior)
let slice = AddCategorySlice.make(~dcbEventLog=log, ~publishJsons=publishJsonsOutput)
```
*/
module type T = {
  module Spec: Reventless.StateChangeSlice.Spec
  module Behavior: Reventless.StateChangeSlice.Behavior with module Spec := Spec
  /** `true` when built with `Platform.StateChangeSlice.MakeAsync` — uses FIFO channel, returns `CommandPending`. */
  let isAsync: bool
  type component = Component.t<t, outputs, operations>
  let make: (
    ~dcbEventLog: DcbEventLog.component,
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    /** Produced event-log type→tag-key map, used to drop vacuous (type, tag)
        clause combinations when building the decision-model query. */
    ~tagKeysByEventType: Dict.t<array<string>>=?,
    /** Tag keys declared `@crossPartition` across the produced event schemas —
        a cross-partition scalar command tag fans out into its own single-tag
        decision-read clause. */
    ~crossPartitionTagKeys: array<string>=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
