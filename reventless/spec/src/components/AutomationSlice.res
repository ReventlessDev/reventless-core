/**
Module types for a DCB automation slice (TODO List Pattern).

An `AutomationSlice` listens to the shared `DcbEventLog` event topic, accumulates
pending work items (TODO list), and processes them exactly once by issuing commands.
Completion events mark TODO items as done, closing the automation loop.

```
Event(s) → TODO List (read model) → Processor → Command → Event(s)
```

Plan 02 splits the merged spec into two module types:

- `Spec` — types, identity, schemas, configuration constants. Per D2,
  `todoItem` lives here (the persisted TODO state has a schema queried for
  sweeping pending items — externally-observable, like ReadModel state).
- `Automation` — the three pure functions `collect`, `resolve`, `process`.

@example
```rescript
// ShipOrder.res
let name = "ShipOrder"

@schema type todoItem = {orderId: string, shippingAddress: string}
@schema type command = CreateShipment({orderId: @s.matches(DcbTag.string) string, address: string})

let collect = event => switch event {
  | OrderPlaced({orderId, shippingAddress}) =>
    [(orderId, {orderId, shippingAddress})]
  | _ => []
}

let resolve = event => switch event {
  | ShipmentCreated({orderId}) => Some(orderId)
  | _ => None
}

let process = (id, item) =>
  Some((id, CreateShipment({orderId: item.orderId, address: item.shippingAddress})))

let maxRetries = 3
let heartbeatInterval = 60
```
*/

/**
The lean Spec for an AutomationSlice — types, identity, schemas, sweep config.

Plan 04 dropped `consumedEvent` from the Spec — the framework now derives the
consumed-event set from each per-source Mapping's `sourceEventSchema`, so a
manually-declared union is no longer necessary. Single-source slices have one
`Mapping` whose `sourceEventSchema` IS the consumed-event schema; multi-source
slices have several Mappings and the framework walks all of them.
*/
module type Spec = {
  /** Logical name of this automation slice (used as a component prefix). */
  let name: string
  let moduleUrl: string

  /** The TODO item state — what data is accumulated for each pending work item. Must carry `@schema`. */
  @schema
  type todoItem

  /** The command type produced by the processor. Must carry `@schema`. */
  @schema
  type command

  /** Maximum number of retries for a failed processing attempt. */
  let maxRetries: int

  /** Heartbeat interval in seconds for sweeping pending/failed items. */
  let heartbeatInterval: int

  /** Name of the aggregate or StateChangeSlice that receives the produced command. */
  let targetName: string
}

// ── Plan 04: Mixed-source mappings ───────────────────────────────────────────
//
// An AutomationSlice can declare per-source mappings that consume Aggregate
// events alongside the slice's own DcbEventLog events. Each mapping carries its
// own `collect`/`resolve` (over the source's `event` type) plus a `toTags`
// validation step run before each command publish. `process` remains shared in
// the slice's `Automation` module since it operates on `todoItem` regardless of
// the originating source.

/**
Ambient deployment context plumbed to every mapping function.

`Plugin_Builder` constructs this from its existing `~environment`, `~name` and
related parameters. `collect` and `resolve` use it to complete partial event
payloads (e.g. when a DCB tag field is supplied by deployment metadata rather
than the source event); `toTags` uses it to validate that all tag fields on the
target command will be populated.

The record is intentionally narrow — extending it is a deliberate framework
change, not an open-dict escape hatch. Runtime registry lookups are out of
scope (see Plan 04 / decision 3).
*/
type context = {
  environment: string,
  platformName: string,
  pluginName: string,
  sliceName: string,
}

/**
A compiled per-source-to-AutomationSlice mapping.

Created by `AutomationSlice.Mapping.Make(Source, Target, Impl)`. The mapping
binds `sourceEvent` (decode target) plus `collect`/`resolve` to the slice's
`todoItem` type. `process` remains in the slice's `Automation` module — it is
source-agnostic.

Validation belongs upstream of the mapping: `collect` should return `[]` for
events that shouldn't enter the TODO list, and the command schema's
`@compositePartitionTag` / `@s.matches(DcbTag.string)` annotations enforce
DCB-tag invariants at encode time (failures mark the item Failed → retry).
*/
module type Mapping = {
  module SourceId: Id.T
  @schema
  type sourceEvent
  type todoItem
  type command
  let sourceEventSchema: S.t<sourceEvent>
  let sourceName: string
  let collect: (sourceEvent, context) => array<(string, todoItem)>
  let resolve: sourceEvent => option<string>
}

/**
The Automation — the source-agnostic processing function.

Plan 04 moved `collect` and `resolve` to per-source `Mapping` modules (where
they switch over the source's own `event` type). `process` stays here because
it operates on `todoItem`, which is uniform across sources.

The "close PPX gaps" plan merged the previous `Mappings` shape into this type:
the same module that exposes `process` also exposes the per-source `mappings`
array and the inner `module type Mapping`. This collapses the Plan 04 3-arg
`AutomationSlice.Make(Spec, Automation, Mappings)` into a 2-arg
`Make(Spec, Automation)` and lets the merged `_Automation.res` file (process +
per-source `Mapping.Make` + `let mappings`) live as a single source file.
*/
module type Automation = {
  module Spec: Spec

  /**
  Process: given a pending TODO item, produce a command.
  The processor calls this for each pending item. Returns the target ID and command.
  May return `None` to skip processing (e.g., wait for more data).
  */
  let process: (string, Spec.todoItem) => option<(string, Spec.command)>

  /**
  The retry budget is spent: this item will never be processed again.

  Return `Some((targetId, command))` to tell the domain, or `None` to say nothing.

  Abandonment is an outcome, not the absence of one, and the framework cannot
  publish it on a slice's behalf: the command would have to name a target, and
  which target is exactly what this module knows and the framework does not. So
  the choice is declared here even when the answer is `None` — a slice that stays
  silent says so on purpose.

  The row is marked `Abandoned` either way; this decides only whether anything
  downstream hears about it.
  */
  let onExhausted: (string, Spec.todoItem) => option<(string, Spec.command)>

  /** File URL of this Automation module (`import.meta.url`). */
  let moduleUrl: string

  /**
  The per-source `Mapping` type — substituted onto the slice's `Spec`. The
  PPX-injected `module M = Reventless.AutomationSlice.Mappings.Make(Spec)`
  + `module type Mapping = M.Mapping` produces exactly this shape; legacy
  3-file files re-export it via `module type Mapping = <Stem>_Mappings.Mapping`.
  */
  module type Mapping = Mapping
    with type todoItem = Spec.todoItem
    and type command = Spec.command

  /**
  The per-source mappings registered with this slice. Each entry is a first-class
  module satisfying `Mapping`. The framework walks these to discover source
  topics and dispatch decoded events to the matching `collect`/`resolve`.
  */
  let mappings: array<module(Mapping)>
}

/**
The implementation passed to `AutomationSlice.Mapping.Make`. Caller-supplied
`collect`/`resolve` are bound to source/target types via destructive
substitution in the functor.
*/
module type MappingImpl = {
  type sourceEvent
  type todoItem
  type command
  let collect: (sourceEvent, context) => array<(string, todoItem)>
  let resolve: sourceEvent => option<string>
}

/**
A collection of `Mapping` modules for a single AutomationSlice target.

Pass a `Mappings` module to the AutomationSlice plugin builder to register all
source-to-slice mappings. The shape mirrors `Projection.Mappings` for
ReadModels.

@example
```rescript
// AutoFulfillment_Mappings.res
module M = Reventless.AutomationSlice.Mappings.Make(AutoFulfillmentSpec)
module type Mapping = M.Mapping

let mappings: array<module(Mapping)> = [
  module(FromOrderShipped),
  module(FromStockReserved),
]
```
*/
module type Mappings = {
  module Target: Spec
  module type Mapping = Mapping
    with type todoItem = Target.todoItem
    and type command = Target.command
  let moduleUrl: string
  let mappings: array<module(Mapping)>
}

/**
Builds an `AutomationSlice.Mapping` from a `Source`, the slice's `Spec`, and a
`MappingImpl`.

@example
```rescript
// AutoFulfillment/FromOrderShipped.res
module FromOrderShipped = Reventless.AutomationSlice.Mapping.Make(
  OrderSpec,                    // Source: Aggregate spec module
  AutoFulfillmentSpec,          // Target: this slice's spec
  {
    let collect = (event, _ctx) =>
      switch event {
      | OrderSpec.OrderShipped({orderId, productId}) =>
        [(orderId ++ ":" ++ productId, {AutoFulfillmentSpec.orderId, productId})]
      | _ => []
      }

    let resolve = event =>
      switch event {
      | OrderSpec.OrderRefunded({orderId, productId}) =>
        Some(orderId ++ ":" ++ productId)
      | _ => None
      }
  },
)
```
*/
module Mapping = {
  module Make = (
    Source: Projection.Source,
    Target: Spec,
    Impl: MappingImpl
      with type sourceEvent := Source.event
      and type todoItem := Target.todoItem
      and type command := Target.command,
  ): (
    Mapping
      with type sourceEvent = Source.event
      and type todoItem = Target.todoItem
      and type command = Target.command
      and module SourceId = Source.Id
  ) => {
    module SourceId = Source.Id
    @schema
    type sourceEvent = Source.event
    type todoItem = Target.todoItem
    type command = Target.command
    let sourceName = Source.name
    let collect = Impl.collect
    let resolve = Impl.resolve
  }
}

module Mappings = {
  module Make = (Target: Spec) => {
    module type Mapping = Mapping
      with type todoItem = Target.todoItem
      and type command = Target.command
  }
}

