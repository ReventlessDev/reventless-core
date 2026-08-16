---
title: StateViewSlice
date: 2026-02-18
draft: false
---

For a short summary of StateViewSlice, see [Reventless Components Overview.](../component-overview.md)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/internals/component-structure-pattern), using separate files for interface definitions (`StateViewSlice.res`), builder logic (`StateViewSlice_Builder.res`), and callback/handler logic (`StateViewSlice_Callback.res`).
:::

## Overview

```d2
Plugin: Plugin { class: plugin-area }
DcbEventLog: DcbEventLog { class: dcb-event-log }
StateViewSlice: StateViewSlice { class: state-view-slice }
QueryDb: QueryDb { class: query-db }

DcbEventLog -> StateViewSlice: events { class: event-flow }
StateViewSlice -> QueryDb: project to { class: projection-flow }

Plugin -> DcbEventLog: creates
Plugin -> StateViewSlice: creates
Plugin -> QueryDb: creates
```

The **StateViewSlice** is a DCB (Dynamic Consistency Boundary) component that projects events from a shared DcbEventLog into a QueryDb-backed read model. It implements the projection pattern where events are transformed into state updates.

## Purpose and Responsibilities

- **Responsibility**: Listen to events from DcbEventLog and project them into a QueryDb for efficient reading
- **In**: Events from DcbEventLog (subscribed via EventCollector)
- **Out**: State updates to QueryDb
- **Key Feature**: Complements StateChangeSlice by providing read-optimized views of the event-sourced state

## Relationship with DCB

StateViewSlice works alongside StateChangeSlice in the DCB architecture:

```d2
DCBArchitecture: DCB Architecture {
  class: plugin-area

  Slices: DCB Slices {
    class: slices-area

    SCS: State Change Slices {
      class: slices-area
      SCS1: CreateItem Slice { class: state-change-slice }
      SCS2: RenameItem Slice { class: state-change-slice }
    }

    SVS: State View Slices {
      class: view-slices-area
      SVS1: ItemView Slice { class: state-view-slice }
      SVS2: InventoryView Slice { class: state-view-slice }
    }
  }

  DcbEventLog: DcbEventLog\nShared Event Log { class: dcb-event-log }
  QueryDb1: QueryDb\nItem Views { class: query-db }
  QueryDb2: QueryDb\nInventory { class: query-db }

  DcbEventLog -> Slices.SCS.SCS1: events { class: event-flow }
  DcbEventLog -> Slices.SCS.SCS2: events { class: event-flow }
  DcbEventLog -> Slices.SVS.SVS1: events { class: event-flow }
  DcbEventLog -> Slices.SVS.SVS2: events { class: event-flow }

  Slices.SCS.SCS1 -> DcbEventLog: append events { class: event-flow }
  Slices.SCS.SCS2 -> DcbEventLog: append events { class: event-flow }

  Slices.SVS.SVS1 -> QueryDb1: project to { class: projection-flow }
  Slices.SVS.SVS2 -> QueryDb2: project to { class: projection-flow }
}
```

## Component Spec

A StateViewSlice is **split into two files**:

- `<Name>.res` — the **spec** (`@@reventless.spec`): the local `consumedEvent` and
  `state` `@schema` types.
- `<Name>_Projection.res` — the **projection** (`@@reventless.projection`): a single
  `let project = ({event}) => [...]` function receiving a `consumed` envelope
  `{event, meta, recordedAt}`.

The spec file. `@@reventless.spec` injects `name`, `module Id`, `moduleUrl`,
`let config = config()`, and `let subIdConfig = None`:

```rescript title="Item/StateViewSliceStream/Items.res" showLineNumbers
@@reventless.spec

@schema
type consumedEvent =
  | Created({id: string, name: string})
  | Updated({id: string, name: string})
  | Deleted({id: string})

@schema
type state = {name: string}
```

The projection file. `@@reventless.projection` injects `open Reventless.Projection`
(so `Set`, `Update`, `UpdateWithDefault`, `Delete` are in scope unqualified) and
brings the spec module into scope. `project` receives a `consumed` envelope
`{event, meta, recordedAt}`; destructure `({event})` when you only need the
payload. `meta` is `Reventless.Message.meta` (producer info incl. `meta.time`, the
producer timestamp, and `meta.user`) and `recordedAt: string` is the storage
timestamp:

```rescript title="Item/StateViewSliceStream/Items_Projection.res" showLineNumbers
@@reventless.projection

let project = ({event}) =>
  switch event {
  | Created({id, name}) => [Set(id, {name: name})]
  | Updated({id, name}) => [Update(id, state => {...state, name})]
  | Deleted({id}) => [Delete(id)]
  }
```

There is no `DcbEventLogSpec` reference — the slice declares its own local
`consumedEvent` union.

### Spec Fields Explained

In the spec file (`@@reventless.spec` injects `name`, `module Id`, `moduleUrl`):

| Field | Type | Description |
|-------|------|-------------|
| `consumedEvent` | `@schema` [type](../rescript-syntax.md#ppx) | The local subset of event variants this slice projects |
| `state` | `@schema` [type](../rescript-syntax.md#ppx) | State type for the read model (schema auto-generated) |

In the `_Projection.res` file:

| Field | Type | Description |
|-------|------|-------------|
| `project` | `Reventless.StateViewSlice.consumed<consumedEvent> => array<Projection.action<state>>` | Function to transform a consumed event envelope into state actions |

## Runtime Behavior

### Event Processing Flow

```d2
shape: sequence_diagram

DcbEventLog: DcbEventLog { class: dcb-event-log }
EventCollector: EventCollector { class: event-collector }
StateViewSlice: StateViewSlice
QueryDb: QueryDb { class: query-db }
Storage: DynamoDB { class: aws-service }

DcbEventLog -> EventCollector: new events published
EventCollector -> StateViewSlice: "eventsHandler(events)"
StateViewSlice -> StateViewSlice: "project(event)"
StateViewSlice -> StateViewSlice: Generate Projection.actions
StateViewSlice -> QueryDb: "handleActions(actions)"
QueryDb -> Storage: "Load current state (if needed)"
QueryDb -> Storage: Save/Update/Delete state
Storage --> QueryDb: result
QueryDb --> StateViewSlice: result
StateViewSlice --> EventCollector: completion
```

### Projection Actions

In the `_Projection.res` file, `@@reventless.projection` injects
`open Reventless.Projection`, so the action constructors (`Set`, `Update`,
`UpdateWithDefault`, `Delete`) are in scope unqualified:

```rescript title="Item/StateViewSliceStream/Items_Projection.res"
@@reventless.projection

let project = ({event}) =>
  switch event {
  | ItemCreated({itemId, name}) => [Set(itemId, {name, createdAt: Date.now()})]
  | ItemRenamed({itemId, newName}) => [Update(itemId, state => {...state, name: newName})]
  | ItemDeleted({itemId}) => [Delete(itemId)]
  | StockAdjusted({itemId, delta}) =>
    // UpdateWithDefault handles case where item doesn't exist yet
    [UpdateWithDefault(itemId, {count: 0}, state => {...state, count: state.count + delta})]
  }
```

## Key Design Annotations

StateViewSlice supports the same PPX annotations on `@schema type state` as ReadModel. Annotations on state fields automatically generate `let makeId`, `let subIdConfig`, and `let config`. These annotations go on the spec file's `@schema type state`:

```rescript title="OrderLineItems/StateViewSliceStream/OrderLineItems.res" showLineNumbers
@@reventless.spec

@schema
type state = {
  @id orderId: string,               // generates: let makeId
  @subId lineItemId: string,         // generates: let subIdConfig — enables sort key queries
  @index categoryId: string,         // generates: let config with a secondary index
  @resolves({table: "Products", field: "product"}) productId: string,
  quantity: int,
}

@schema
type consumedEvent =
  | LineItemAdded({orderId: string, lineItemId: string, productId: string, categoryId: string, quantity: int})
  | LineItemRemoved({orderId: string, lineItemId: string})
```

The `project` function lives in the sibling `_Projection.res` file, where
`@@reventless.projection` injects `open Reventless.Projection` (so `Set`,
`Update`, `UpdateWithDefault`, and `Delete` are in scope unqualified):

```rescript title="OrderLineItems/StateViewSliceStream/OrderLineItems_Projection.res" showLineNumbers
@@reventless.projection

let project = ({event}) =>
  switch event {
  | LineItemAdded({orderId, lineItemId, productId, categoryId, quantity}) =>
    [Set(lineItemId, {orderId, lineItemId, productId, categoryId, quantity})]
  | LineItemRemoved({lineItemId}) => [Delete(lineItemId)]
  }
```

For the full annotation reference, see [PPX annotations](../rescript-syntax.md#reventless-ppx-annotations).

## Comparison with ReadModel

| Aspect | ReadModel | StateViewSlice |
|--------|-----------|----------------|
| **Event Source** | Multiple EventTopics | Single DcbEventLog |
| **Mappings** | Complex mapping system | Single projection function |
| **Spec** | Reventless.ReadModel.Spec | Custom Spec with project function |
| **Key annotations** | `@id`, `@subId`, `@index`, `@resolves` on state fields | Same — identical PPX annotation support |
| **Use Case** | General-purpose read models | DCB-specific view projections |

## Comparison with StateChangeSlice

| Aspect | StateChangeSlice | StateViewSlice |
|--------|-----------------|----------------|
| **Purpose** | Handle commands and decide on events | Project events into read model |
| **Input** | Commands from CommandTopic | Events from DcbEventLog EventTopic |
| **Output** | Appends events to DcbEventLog | Updates QueryDb state |
| **Pattern** | Decision/command pattern | Projection pattern |

## Pulumi Outputs

```rescript
type outputs = {
  resources: array<Reventless.Adapter.resource>,
  queryDb: QueryDb.outputs,
}
```

The StateViewSlice creates its own QueryDb:
- DynamoDB table for state storage
- AppSync resolvers for querying
- Related IAM roles and policies

## Related Components

- **[DcbEventLog](/framework/runtime-components/dcbeventlog)** - Shared event log for DCB slices
- **[StateChangeSlice](./statechangeslice.md)** - Processes commands and appends events
- **[QueryDb](/framework/runtime-components/querydb)** - Read model storage
- **[ReadModel](./readmodel.md)** - General-purpose read model component
- **[Plugin](./plugin.md)** - Hosts DCB slices and creates shared infrastructure
- **[EventCollector](/framework/runtime-components/eventcollector)** - Consumes events for projection
- **[Usage Guide](../concepts/stateviewslice-usage.md)** - How to use StateViewSlice in your application
