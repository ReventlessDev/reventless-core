# Event Modeling Patterns → Reventless Components

## Mapping Table

| EM Pattern | EM Slice Type | Aggregate Approach | DCB Approach |
|-----------|--------------|-------------------|-------------|
| Command (State Change) | `STATE_CHANGE` | Aggregate (Spec + Behavior) | StateChangeSlice |
| View (State View) | `STATE_VIEW` | ReadModel + Projection | StateViewSlice |
| Automation | `AUTOMATION` | EventMapper / Counter | AutomationSlice |
| Inbound Translation | — | Task (S3 trigger) | InboundTranslationSlice |
| Outbound Translation | — | SideEffectHandler | OutboundTranslationSlice |

## STATE_CHANGE → Reventless

### As Aggregate

Multiple EM command slices on the same entity become **one Aggregate** with multiple command/event variants:

```
EM slices:
  "Add Product" (STATE_CHANGE, context: Catalog)
  "Change Product Name" (STATE_CHANGE, context: Catalog)
  "Change Product Price" (STATE_CHANGE, context: Catalog)

→ Reventless:
  Product.res (Spec: Add | UpdateName | UpdatePrice commands)
  ProductBehavior.res (state machine handling all commands)
```

### As DCB StateChangeSlice

Each EM command slice becomes **one StateChangeSlice file**:

```
EM slices:
  "Add Product" (STATE_CHANGE, context: Catalog)
  "Change Product Name" (STATE_CHANGE, context: Catalog)

→ Reventless:
  AddProduct.res (one slice, one command)
  ChangeProductName.res (one slice, one command)
```

### Field Mapping

| EM Field Type | ReScript Type |
|--------------|--------------|
| `String` | `string` |
| `Int` | `int` |
| `Double` / `Decimal` | `float` |
| `Boolean` | `bool` |
| `UUID` | `string` (with `@s.matches(DcbTag.string)` if entity ID in DCB) |
| `Date` / `DateTime` | `string` (ISO format) |
| `Custom` | Custom record type |
| `List` cardinality | `array<T>` |
| `optional: true` | `option<T>` or `T?` (optional record field) |
| `idAttribute: true` | Entity identity → `@s.matches(DcbTag.string)` in DCB |

## STATE_VIEW → Reventless

### As ReadModel + Projection

```
EM slice:
  "Products View" (STATE_VIEW, context: Catalog)
  depends on: ProductAdded, ProductNameChanged events

→ Reventless:
  ProductsReadModel.res (state type with view fields)
  ProductsProjections.res (Mapping.Make with project function)
```

### As StateViewSlice

```
EM slice:
  "Products View" (STATE_VIEW, context: Catalog)

→ Reventless:
  ProductsView.res (state + consumedEvent + project function)
```

## AUTOMATION → Reventless

```
EM slice:
  "Auto-Ship Order" (AUTOMATION, context: Ordering)
  trigger: OrderPlaced
  resolution: OrderShipped
  action: ShipOrder command

→ Reventless (DCB):
  AutoShipOrder.res (AutomationSlice with collect/resolve/process)

→ Reventless (Aggregate):
  EventMapper or Counter with threshold-based command generation
```

## Translation → Reventless

### Inbound
```
EM: External supplier feed → validate → AddProduct command

→ Reventless (DCB):
  ImportProduct.res (InboundTranslationSlice with translate function)
```

### Outbound
```
EM: OrderPlaced event → send confirmation email

→ Reventless (DCB):
  SendOrderConfirmation.res (OutboundTranslationSlice with collect/translate)

→ Reventless (Aggregate):
  Order_EmailNotification.res (SideEffectHandler with execute function)
```

## What EM JSON Cannot Express

These must be added manually during Reventless code generation:

- `state` type and `initialState` for StateChangeSlices
- `evolve` function logic
- `decide` function guard conditions
- `@s.matches(DcbTag.string)` annotations
- `@schema` attributes
- Extension point specs and mappings
- Plugin composition wiring
- Error variant types (beyond simple rejection)
