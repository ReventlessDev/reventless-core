/**
The aggregate whose events drive this projection.
Used to subscribe to the correct event topic.
*/
module type Source = {
  module Id: Id.T
  let name: string
  @schema
  type event
}

/**
The read model table that stores the projected state.
`subIdConfig` enables composite-key tables (id + sub-id).
*/
module type Target = {
  module Id: Id.T
  let name: string
  @schema
  type state
  let subIdConfig: option<ReadModel.subIdConfig<state>>
}

/**
The outcome of a projection mapping — what to do with the read model state
after processing a source event.

Returned from a `Projection.Mapping` `project` function.
Return `Ignore` (or `[]`) when an event should not affect the read model.

@example
```rescript
// CategoriesProjections.res
let project = ({event, id, _}) => switch event {
  | CategoryAdded({categoryId, name}) =>
    Set(id, {CategoriesReadModel.categoryId, name, archived: false})
  | CategoryRenamed({name}) => Update(id, state => {...state, name})
  | CategoryArchived(_) => Update(id, state => {...state, archived: true})
}
```
*/
type action<'id, 'state> =
  /** Create a new state entry. The entry must not already exist. */
  | Create('id, 'state)
  /** Create many new state entries. Entries must not already exist. */
  | CreateMany(array<('id, 'state)>)
  /** Update an existing entry by applying a transform function. */
  | Update('id, 'state => 'state)
  /** Update many existing entries. */
  | UpdateMany(array<'id>, ('id, 'state) => 'state)
  /** Update an existing entry, or create it with `'state` if it does not exist. */
  | UpdateWithDefault('id, 'state, 'state => 'state)
  /** Update many entries or create them with a default derived from their ID. */
  | UpdateManyWithDefault(array<'id>, 'id => 'state, ('id, 'state) => 'state)
  /** Overwrite the state for an entry, creating it if it does not exist. */
  | Set('id, 'state)
  /** Overwrite the state for many entries. */
  | SetMany(array<'id>, 'id => 'state)
  /** Delete an existing entry. */
  | Delete('id)
  /** Delete many entries. */
  | DeleteMany(array<'id>)
  /** Delete an entry only if the predicate returns true. */
  | DeleteIf('id, 'state => bool)
  /** Delete many entries conditionally. */
  | DeleteManyIf(array<'id>, ('id, 'state) => bool)
  /**
  Create multiple sub-state rows under the same primary ID.
  Used when one event produces several independent sub-entries.
  */
  | CreateMultiState('id, array<'state>)
  /**
  Replace the entire set of sub-state rows for a primary ID.
  The transform receives the current rows and returns the new rows.
  */
  | UpdateMultiState('id, array<'state> => array<'state>)
  /** Update sub-state rows for multiple primary IDs. */
  | UpdateManyMultiStates(array<'id>, ('id, array<'state>) => array<'state>)
  /** No-op. Return this when an event should not affect the read model. */
  | Ignore

/**
A compiled single-source-to-single-target mapping.

Created by `Projection.Mapping.Make(Source, Target, MappingImpl)`.
The `project` function receives a full `Message.event'` envelope and returns
one `action` value.
*/
module type Mapping = {
  //module Source: Source
  //module Target: Target // NOTE: to be destructive substituted
  module SourceId: Id.T
  @schema
  type sourceEvent
  @schema
  type targetState

  let project: Message.event'<string, sourceEvent> => action<string, targetState>
  let sourceEventSchema: S.t<sourceEvent>
  let sourceName: string
  let subIdConfig: option<ReadModel.subIdConfig<targetState>>
  let targetStateSchema: S.t<targetState>
}

/**
A collection of `Mapping` modules for a single read model target.

Pass a `Mappings` module to `Platform.ReadModel.Make` to register all
source-to-target projections for a read model.
*/
module type Mappings = {
  module Target: Target // to be removed via destructive replace in functor call
  module type Mapping = Mapping with type targetState = Target.state
  let moduleUrl: string
  let mappings: array<module(Mapping)>
}

module type MappingImpl = {
  type sourceEvent
  type targetState
  let project: Message.event'<string, sourceEvent> => action<string, targetState>
}

/**
Builds a `Projection.Mapping` from a `Source`, `Target`, and `MappingImpl`.

@example
```rescript
// CategoriesProjections.res
module CategoryMapping = Projection.Mapping.Make(
  Category,
  CategoriesReadModel,
  {
    let project = ({event, id, _}) => switch event {
      | CategoryAdded({categoryId, name}) =>
        Set(id, {CategoriesReadModel.categoryId, name, archived: false})
      | CategoryRenamed({name}) => Update(id, state => {...state, name})
      | CategoryArchived(_) => Update(id, state => {...state, archived: true})
    }
  },
)
```
*/
module Mapping = {
  module Make = (
    Source: Source,
    Target: Target,
    MappingImpl: MappingImpl with type sourceEvent := Source.event and type targetState := Target.state,
  ): (Mapping with type targetState = Target.state and type sourceEvent = Source.event and module SourceId = Source.Id) => {
    module SourceId = Source.Id
    @schema
    type sourceEvent = Source.event
    @schema
    type targetState = Target.state
    let project = MappingImpl.project
    let sourceName = Source.name
    let subIdConfig = Target.subIdConfig
  }
}

module Mappings = {
  module Make = (Target: Target) => {
    module type Mapping = Mapping with type targetState = Target.state
  }
}

/**
Builds a `Projection.Source` module for a DCB EventLog.

A DCB-source `Mapping.Make` takes a `Source` whose `name` matches the key under
which `Plugin_Builder` registers the DCB topic in `allEventTopics`
(`<pluginName>DcbEventLog`). This helper is a thin convenience that asserts the
`Source` shape over an inline DCB event subset — the `event` type only needs to
enumerate the variants this consumer projects (others fall through as decode
errors and the runtime treats them as `Ignore`).

@example
```rescript
// catalog/src/Product/ReadModel/CatalogDcbSource.res
module CatalogDcbSource = Reventless.Projection.DcbSource.Make({
  let name = "CatalogDcbEventLog"
  @schema
  type event =
    | ProductAdded({productId: string, name: string, price: float})
    | ProductRenamed({productId: string, name: string})
})
```

Then in your projections file:
```rescript
module ProductsFromDcb = Reventless.Projection.Mapping.Make(
  CatalogDcbSource,
  ProductsReadModel,
  { let project = ({event, id, _}) => switch event {
      | ProductAdded({name}) => Set(id, {ProductsReadModel.name})
      | ProductRenamed({name}) => Update(id, s => {...s, name})
    } },
)
```

`module Id` is `Reventless.Id.String` for DCB sources — DCB events are
content-addressed and have no aggregate-style stream ID.
*/
module DcbSource = {
  module type Definition = {
    let name: string
    @schema
    type event
  }
  // Returned signature is left structurally inferred (NOT sealed under `Source`)
  // so that variant constructors of `D.event` remain accessible to callers
  // writing `switch msg.event { | ProductAdded(_) => ... }`. The result still
  // satisfies `Source` structurally and is accepted by `Mapping.Make` as such.
  module Make = (D: Definition) => {
    module Id = Id.String
    let name = D.name
    type event = D.event
    let eventSchema = D.eventSchema
  }
}
