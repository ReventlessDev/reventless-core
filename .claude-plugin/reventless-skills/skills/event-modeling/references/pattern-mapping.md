# Event Modeling Patterns → Reventless Components

## Mapping Table

| EM Pattern | EM Slice Type | Aggregate Approach | DCB Approach |
|-----------|--------------|-------------------|-------------|
| Command (State Change) | `STATE_CHANGE` | Aggregate (Spec + Behavior) | StateChangeSlice |
| View (State View) | `STATE_VIEW` | ReadModel + Projection | StateViewSlice |
| Automation | `AUTOMATION` | AutomationSlice (Aggregate source), or EventMapper / Counter | AutomationSlice |
| Inbound Translation | — | InboundTranslationSlice (`targetName` = the Aggregate), or Task (S3 trigger) | InboundTranslationSlice |
| Outbound Translation | — | OutboundTranslationSlice (`sourceNames` = the Aggregate), or SideEffectHandler | OutboundTranslationSlice |

The automation and translation slices work in both approaches. They listen to Aggregate events, DCB events or both, and send commands to an Aggregate or a StateChangeSlice. The Aggregate column's second option is the lighter one, without a TODO list, retries or completion tracking.

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

→ Reventless (DCB or Aggregate source):
  AutoShipOrder.res (AutomationSlice spec)
  AutoShipOrder_Automation.res (one Mapping.Make per source + collect/resolve/process)

→ Reventless (Aggregate, stateless):
  EventMapper, or Counter for threshold-based command generation
```

An AutomationSlice whose trigger is an Aggregate event names that Aggregate as a source in its mappings. Use an EventMapper only when the reaction needs no TODO list (no retries, nothing to resolve).

## Translation → Reventless

### Inbound
```
EM: External supplier feed → validate → AddProduct command

→ Reventless:
  ImportProduct.res (InboundTranslationSlice with translate function)
  targetName = the StateChangeSlice or the Aggregate that handles AddProduct
```

### Outbound
```
EM: OrderPlaced event → send confirmation email

→ Reventless (tracked, with retries):
  SendOrderConfirmation.res (OutboundTranslationSlice with collect/translate)
  sourceNames = [] for the plugin's own DCB log, or ["Order"] for an Order aggregate

→ Reventless (Aggregate, fire-and-forget):
  Order_EmailNotification.res (SideEffectHandler with execute function)
```

## What EM JSON Cannot Express

The `reventless-codegen` importer writes the Spec (`@schema` types), the GWT scenarios and a compiling skeleton per slice. `generate-plugin` writes the plugin wiring. What remains is authored by hand or with `reventless-app`:

- `state` type and `initialState` for StateChangeSlices
- `evolve` function logic
- `decide` function guard conditions
- DCB tag overrides (`@partitionTag`, `@dcbTag`, `@noDcbTag`) where the inferred partition is not the one you want
- Extension point specs and mappings
- Error variant types (beyond simple rejection)
