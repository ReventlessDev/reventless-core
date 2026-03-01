/**
Module type for a DCB write-side state change slice specification.

A `StateChangeSlice` is the DCB equivalent of an aggregate: it processes
commands by reading the relevant events from a shared `DcbEventLog`, building
a `decisionModel` (ephemeral read model), and appending new events conditioned
on no concurrent changes to the same entities.

@example
```rescript
// AddCategory.res
let name = "AddCategory"
module DcbEventLogSpec = CatalogEventLog

@schema type command = AddCategory({categoryId: @s.matches(DcbTag.string) string, name: string})
@schema type error = CategoryAlreadyExists

type decisionModel = {exists: bool, archived: bool}
let initialDecisionModel = {exists: false, archived: false}

let reduce = (model, event) => switch event {
  | CategoryAdded(_) => {exists: true, archived: false}
  | CategoryArchived(_) => {...model, archived: true}
  | _ => model
}

let decide = (model, command) => switch command {
  | AddCategory({categoryId, name}) =>
    if model.exists { Error(CategoryAlreadyExists) }
    else { Ok([CategoryAdded({categoryId, name})]) }
}

let commandSchema = S.schema(s =>
  AddCategory({categoryId: s.matches(DcbTag.string), name: s.matches(S.string)}))
```
*/
module type Spec = {
  /** Logical name of this slice (used as a command topic prefix). */
  let name: string

  /** The DCB event log spec this slice appends events to. */
  module DcbEventLogSpec: DcbEventLog.Spec

  /** Commands this slice handles. Must carry `@schema`. */
  @schema
  type command

  /** Business rule violation errors. Must carry `@schema`. */
  @schema
  type error

  /**
  The ephemeral decision model built by replaying relevant events.
  Not persisted — reconstructed for each command by reading from the DCB log.
  */
  type decisionModel

  /** The initial (empty) decision model before any events have been applied. */
  let initialDecisionModel: decisionModel

  /**
  Folds one DCB event into the decision model during the read phase.
  Must be a pure function — no side effects.
  */
  let reduce: (decisionModel, DcbEventLogSpec.event) => decisionModel

  /**
  Decides what events to append given the current decision model and the command.
  Return `Ok(events)` to append, or `Error(error)` to reject the command.
  */
  let decide: (decisionModel, command) => result<array<DcbEventLogSpec.event>, error>

  /** Schema for the command type — used to extract DCB tags for the conditional read. */
  let commandSchema: S.t<command>
}

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
  module Spec: Spec
  type dcbEventLogComponent
  type component
  let make: (
    ~dcbEventLog: dcbEventLogComponent,
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
