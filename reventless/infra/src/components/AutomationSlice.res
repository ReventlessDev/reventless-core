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
  module Spec: Reventless.AutomationSlice.Spec
  module Automation: Reventless.AutomationSlice.Automation with module Spec := Spec
  type component = Component.t<t, outputs, operations>
  let queryDbName: string
  /** Names of all sources this slice consumes (deduplicated). Used by
      `Plugin_Builder` for the source-name fail-fast assembly check. */
  let sourceNames: array<string>
  let make: (
    ~allEventTopics: EventTopic.allOutputs,
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~context: Reventless.AutomationSlice.context,
    ~runtime: RuntimeHints.t=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
