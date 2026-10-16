/**
Deploy-time outputs produced when an `AutomationSlice` is provisioned.

- `resources` — the underlying infrastructure (e.g. SQS subscription)
- `queryDb` — the DynamoDB table for the TODO list
*/
type outputs = {
  resources: array<Adapter.resource>,
  queryDb: QueryDb.outputs,
  /** The schedules store, made only for a slice that maps the `Clock`. */
  schedulesDb?: QueryDb.outputs,
}

/**
The platform's schedules of one slice. It knows only when: each schedule is a key and
a time, and its firing reaches the slice as `Tick({key, at})`. A platform may name a
schedule otherwise than by its key (EventBridge Scheduler hashes a key it refuses),
so what it holds is read as names.
*/
type platformSchedules = {
  /** Sets the key's schedule, replacing the one it has. */
  put: (~key: string, Reventless.Schedule.time) => promise<unit>,
  /** Removes a schedule by its platform name; one already gone is no error. */
  removeName: string => promise<unit>,
  /** The names of the schedules the platform holds for the slice. */
  names: unit => promise<array<string>>,
  /** The name the platform gives the key's schedule. */
  nameOf: string => string,
}

/**
Runtime operations exposed by an `AutomationSlice` component.

- `enqueueEvent` — push events into the slice's projection queue
- `processPending` — run Phase 2 over the pending and failed items and write the TODO list back; what a sweep runs
*/
type operations = {
  enqueueEvent: EventCollector.enqueueEvent,
  processPending: unit => promise<unit>,
  /** Delivers `Tick({key, at})` from the `Clock` source, then runs Phase 2: what the
      platform's Scheduler does when one of the slice's schedules comes due. */
  tick: (~key: string, ~at: float) => promise<unit>,
  /** Brings the declared time into the schedule rows and the platform's schedules in
      line with the rows: what a deploy or a start runs. */
  reconcileSchedules: unit => promise<unit>,
  /** Rebuilds the schedule rows from the slice's source events, in order, then
      reconciles. */
  rebuildSchedules: array<JSON.t> => promise<unit>,
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
  /** The schedules store's name, for a slice that maps the `Clock`. */
  let schedulesDbName: option<string>
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
