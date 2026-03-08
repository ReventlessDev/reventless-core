# Hybrid Aggregate + DCB Approach: Analysis

## 1. Motivation

The two existing online-shop examples each demonstrate a single approach:

- **online-shop-aggregates**: Every entity is modeled as an aggregate with its own event log, command topic, and behavior module. Cross-entity coordination relies on extension points and shadow aggregates.
- **online-shop-dcb**: Every entity shares a DCB event log per plugin. Decision models filter events by tagged entity IDs. Cross-entity decisions are natural because all events live in one log.

Neither example explores **mixing both approaches within the same plugin** — yet the framework already supports this. The `Plugin.make` function accepts both `~aggregates` and `~dcbSpec` as optional parameters, meaning a single plugin can contain aggregates alongside DCB slices, each using their own event storage but sharing the same GraphQL schema.

The question is: **when does mixing make sense, and what does the hybrid architecture look like in practice?**

---

## 2. When Each Approach Fits Best

### Aggregates Excel When

- The entity is **self-contained** — commands only need the entity's own history to make decisions
- The entity has a **clear lifecycle state machine** (e.g., Active → Deactivated, Placed → Shipped → Cancelled)
- There are **no cross-entity consistency requirements** at command time
- The entity benefits from **isolated event streams** for performance (no irrelevant events in the log)
- The entity is **high-volume** and would create noise in a shared log

### DCB Excels When

- A command's validity depends on **multiple entity types** (e.g., placing an order requires checking product availability AND customer status)
- The **consistency boundary varies per command** — some commands touch one entity, others touch several
- You want to **avoid shadow aggregates** and extension-based synchronization for entities within the same plugin
- **Tag-based filtering** provides a natural way to scope events (e.g., all events for a given productId across different entity types)
- The domain has **complex cross-entity invariants** that would require elaborate inter-aggregate coordination

### The Hybrid Sweet Spot

Mix both when a plugin contains entities of **both kinds**: some that are self-contained and some that participate in cross-entity decisions. Forcing all entities into DCB adds noise to the shared log for truly independent entities. Forcing all entities into aggregates creates artificial coupling through shadow aggregates and extension-based sync for entities that naturally share consistency boundaries.

---

## 3. Hybrid Online Shop Design

### 3.1 Catalog Plugin — Hybrid

**Aggregate-based (independent entities):**

| Component | Rationale |
|-----------|-----------|
| **Category** aggregate | Categories are fully independent. Adding, renaming, or archiving a category never requires checking other entities. A simple state machine (Active / Archived) with its own event stream. |

**DCB-based (cross-entity consistency):**

| Component | Rationale |
|-----------|-----------|
| **Product** + **ProductDemand** share a DCB event log | ProductDemand tracks how many orders reference each product. In the aggregate approach, this requires an extension (OrdersExtension) to create commands for a separate ProductDemand aggregate, with a shadow of Order events. In DCB, product and demand events coexist in one log — the ProductDemand decision model simply replays demand events filtered by productId, and the ProductDemandView projects both Product and demand events from the same log. No inter-aggregate sync needed within the plugin. |

**Why not put Category in the DCB log too?** Category events (Added, Renamed, Archived) have no relationship to Product/Demand events. Including them would mean every Product decision model replay also scans Category events (filtered out but still read). Keeping Category as a separate aggregate avoids this overhead and keeps the DCB log focused on related entities.

**Plugin composition:**

```
CatalogPlugin (Hybrid)
├── Aggregates
│   └── Category (own EventLog)
│       ├── Commands: Add, Rename, Archive
│       ├── Events: Added, Renamed, Archived
│       └── ReadModel: CategoriesReadModel
│
├── DCB EventLog (shared: Product + ProductDemand)
│   ├── StateChangeSlices
│   │   ├── AddProduct
│   │   ├── ChangeProductName
│   │   ├── ChangeProductDescription
│   │   ├── ChangeProductPrice
│   │   └── RecordProductDemand / RevokeDemand
│   ├── StateViewSlices
│   │   ├── ProductsView
│   │   └── ProductDemandView
│   └── InboundTranslationSlice
│       └── ImportProduct
│
├── ExtensionPoint: ProductsExtensionPoint
│   └── Maps Product events → public API
└── Extension: OrdersExtension
    └── Routes demand signals → RecordProductDemand slice
```

### 3.2 Ordering Plugin — Hybrid

**Aggregate-based (independent entities):**

| Component | Rationale |
|-----------|-----------|
| **Customer** aggregate | Customers are fully independent. Registering, updating email/address, or deactivating a customer never requires checking orders or products. Clean lifecycle state machine (Active / Deactivated). |

**DCB-based (cross-entity consistency):**

| Component | Rationale |
|-----------|-----------|
| **Order** + **CatalogProduct** share a DCB event log | In the aggregate approach, CatalogProduct is a shadow aggregate synced via ProductsExtension. When placing an order, there's no built-in way to validate that all referenced products exist and are available — the Order aggregate would need to query a read model or trust the caller. In DCB, the PlaceOrder decision model can replay CatalogProduct events filtered by the relevant productIds to verify availability as part of the same decision. The consistency boundary dynamically spans Order and CatalogProduct events. |

**Why not put Customer in the DCB log?** Customer lifecycle events (Registered, EmailChanged, Deactivated) are completely independent of Order/CatalogProduct events. A PlaceOrder command does not need to validate customer status against customer events in the same log — it receives the customerId as input and the customer's validity is the Customer aggregate's responsibility. Keeping Customer as an aggregate avoids polluting the Order+CatalogProduct event stream.

**Advanced hybrid benefit — cross-entity validation in PlaceOrder:**

In the pure aggregate approach, `PlaceOrder` can only check its own Order history (e.g., "does this order already exist?"). It cannot check whether the referenced products are available without querying a read model (eventual consistency) or relying on the caller.

In the hybrid approach, since Order and CatalogProduct share a DCB event log, the `PlaceOrder` decision model can:

1. Filter events by the requested productIds (via DCB tags)
2. Verify each product has a `CatalogProductSynced` event (product exists)
3. Check for no `CatalogProductRemoved` event (product still available)
4. Only then accept the PlaceOrder command

This provides **transactional consistency across Order and CatalogProduct** without read model queries or saga-like coordination.

**Plugin composition:**

```
OrderingPlugin (Hybrid)
├── Aggregates
│   └── Customer (own EventLog)
│       ├── Commands: Register, UpdateEmail, UpdateAddress, Deactivate
│       ├── Events: Registered, EmailUpdated, AddressUpdated, Deactivated
│       └── ReadModel: CustomersReadModel
│
├── DCB EventLog (shared: Order + CatalogProduct)
│   ├── StateChangeSlices
│   │   ├── PlaceOrder (decision model spans Order + CatalogProduct events)
│   │   ├── ShipOrder
│   │   ├── CancelOrder
│   │   └── SyncCatalogProduct
│   ├── StateViewSlices
│   │   ├── OrdersView
│   │   └── AvailableProductsView
│   ├── AutomationSlice
│   │   └── AutoShipOrder
│   └── OutboundTranslationSlice
│       └── SendOrderConfirmation
│
├── ExtensionPoint: OrdersExtensionPoint
│   └── Maps Order events → public API
└── Extension: ProductsExtension
    └── Routes catalog sync → SyncCatalogProduct slice
```

### 3.3 Platform Assembly

```
online-shop-hybrid
├── catalog-spec/    (same as existing — ProductsExtensionPoint)
├── ordering-spec/   (same as existing — OrdersExtensionPoint)
├── catalog/         (hybrid: Category aggregate + Product/Demand DCB)
├── ordering/        (hybrid: Customer aggregate + Order/CatalogProduct DCB)
└── online-shop-hybrid/  (platform entry point wiring both plugins)
```

Cross-plugin communication remains identical to both existing examples: extension points and extensions handle the Catalog ↔ Ordering boundary. The hybrid choice is **internal to each plugin** and invisible to other plugins.

---

## 4. Concrete Example: Why the Hybrid Adds Value

### Scenario: Product Demand Tracking (Catalog Plugin)

**Pure aggregate approach (current):**

1. Ordering publishes `ItemOrdered({productId, orderId})` via OrdersExtensionPoint
2. Catalog's OrdersExtension receives it, maps to `ProductDemand.Record({orderId})` command
3. ProductDemand aggregate processes it in its own event log
4. ProductDemandReadModel subscribes to BOTH Product EventTopic AND ProductDemand EventTopic to combine product name with order count

This works but requires:
- A dedicated ProductDemand aggregate (3 files: spec, behavior, builder)
- An extension mapping (OrdersExtension)
- A multi-source read model subscribing to two separate event topics
- The ProductDemand aggregate cannot validate that the productId references a real product (different event log)

**Hybrid approach:**

1. Ordering publishes `ItemOrdered({productId, orderId})` via OrdersExtensionPoint
2. Catalog's OrdersExtension receives it, maps to `RecordProductDemand` command on the shared DCB
3. RecordProductDemand decision model replays events for that productId — sees both `ProductAdded` and prior demand events
4. Decision model validates the product exists before recording demand
5. ProductDemandView projects from the same DCB event log — no multi-source subscription needed

Benefits:
- **Cross-entity validation**: Demand recording validates product existence in the same decision
- **Simpler read model**: ProductDemandView projects from one event log instead of subscribing to two topics
- **Fewer components**: No separate ProductDemand aggregate — just a StateChangeSlice and StateViewSlice
- **Consistent data**: Product name in demand view always matches the product's current name (same event stream)

### Scenario: Order Placement with Product Validation (Ordering Plugin)

**Pure aggregate approach:**

1. PlaceOrder command arrives at Order aggregate
2. Order aggregate can only check: "does this orderId already exist?"
3. It CANNOT check whether the referenced products exist or are available
4. Product availability is assumed — the caller must have checked AvailableProductsReadModel
5. If a product was removed between the read model query and the command, the order references a phantom product

**Hybrid approach:**

1. PlaceOrder command arrives at the DCB event log
2. PlaceOrder decision model replays events tagged with the orderId AND the referenced productIds
3. It verifies: order doesn't exist yet AND all products have `CatalogProductSynced` events AND none have been removed
4. Only then does it emit `OrderPlaced`

Benefits:
- **Atomic cross-entity consistency**: Product availability check and order creation happen in one decision
- **No race condition**: No gap between read model query and command execution
- **Self-documenting**: The decision model explicitly declares what it needs to validate

---

## 5. Framework Changes Required

### 5.1 Already Supported (No Changes Needed)

The Reventless framework **already fully supports** the hybrid approach:

- `Plugin.make` accepts both `~aggregates` and `~dcbSpec` as optional parameters
- `Plugin_Builder.res` handles both simultaneously:
  - Aggregates create their own EventLogs and CommandTopics
  - DCB creates a shared DcbEventLog and DcbCommandTopic
  - Both contribute mutations and queries to a unified GraphQL schema
- Extension points and extensions work identically regardless of whether the source/target uses aggregates or DCB
- The in-memory platform supports both component types in the same plugin

### 5.2 Potential Improvements (Optional, Not Blocking)

These are not required for the hybrid example but would improve the developer experience:

1. **ReadModel sourcing from DCB EventTopic**: Currently, aggregate-based ReadModels subscribe to aggregate EventTopics. If a ReadModel needs to combine data from an aggregate AND DCB events, there is no built-in way to subscribe a traditional ReadModel to the DCB event topic. However, this is not needed for the hybrid example — DCB StateViewSlices handle projections from the DCB log, and aggregate ReadModels handle aggregate projections.

2. **Documentation**: The platform-and-plugin guide covers aggregates and DCB separately. A section on hybrid composition explaining when to use which approach and showing the combined `Plugin.make` call would be valuable.

3. **Example tests**: The hybrid example should include tests that verify:
   - Aggregate commands work independently of DCB state
   - DCB decision models correctly filter events across entity types
   - Extension points bridge aggregate events AND DCB events to external plugins
   - The unified GraphQL schema includes both aggregate mutations and DCB mutations

---

## 6. What Is Needed to Create the Hybrid Example

### 6.1 Package Structure

```
examples/online-shop-hybrid/
├── catalog-spec/
│   ├── src/
│   │   └── ProductsExtensionPoint.res    # Reuse from existing (identical API)
│   ├── rescript.json
│   └── package.json
├── ordering-spec/
│   ├── src/
│   │   └── OrdersExtensionPoint.res      # Reuse from existing (identical API)
│   ├── rescript.json
│   └── package.json
├── catalog/
│   ├── src/
│   │   ├── Plugin/
│   │   │   ├── CatalogEventLog.res       # DCB events: Product + ProductDemand
│   │   │   └── CatalogPlugin.res         # Hybrid: Category aggregate + DCB
│   │   ├── Category/
│   │   │   ├── Aggregate/
│   │   │   │   ├── Category.res          # Aggregate spec (reuse)
│   │   │   │   └── CategoryBehavior.res  # Aggregate behavior (reuse)
│   │   │   └── ReadModel/
│   │   │       ├── CategoriesReadModel.res
│   │   │       └── CategoriesProjections.res
│   │   ├── Product/
│   │   │   ├── StateChangeSlice/
│   │   │   │   ├── AddProduct.res
│   │   │   │   ├── ChangeProductName.res
│   │   │   │   ├── ChangeProductDescription.res
│   │   │   │   └── ChangeProductPrice.res
│   │   │   ├── StateViewSlice/
│   │   │   │   ├── ProductsView.res
│   │   │   │   └── ProductDemandView.res
│   │   │   └── InboundTranslationSlice/
│   │   │       └── ImportProduct.res
│   │   ├── ProductDemand/
│   │   │   └── StateChangeSlice/
│   │   │       └── RecordProductDemand.res
│   │   ├── Extension/
│   │   │   └── OrdersExtension.res       # Inbound: demand → DCB command
│   │   └── ExtensionPoint/
│   │       └── ProductsExtensionPointMapping.res  # Outbound: DCB events → EP
│   ├── tests/
│   │   ├── Category/
│   │   │   └── CategoryBehaviorTest.res
│   │   ├── Product/
│   │   │   └── ProductDecisionTest.res
│   │   └── E2E/
│   │       └── CatalogE2ETest.res        # Tests both aggregate and DCB
│   ├── rescript.json
│   └── package.json
├── ordering/
│   ├── src/
│   │   ├── Plugin/
│   │   │   ├── OrderingEventLog.res      # DCB events: Order + CatalogProduct
│   │   │   └── OrderingPlugin.res        # Hybrid: Customer aggregate + DCB
│   │   ├── Customer/
│   │   │   ├── Aggregate/
│   │   │   │   ├── Customer.res          # Aggregate spec (reuse)
│   │   │   │   └── CustomerBehavior.res  # Aggregate behavior (reuse)
│   │   │   └── ReadModel/
│   │   │       ├── CustomersReadModel.res
│   │   │       └── CustomersProjections.res
│   │   ├── Order/
│   │   │   ├── StateChangeSlice/
│   │   │   │   ├── PlaceOrder.res        # Decision model spans Order + CatalogProduct
│   │   │   │   ├── ShipOrder.res
│   │   │   │   └── CancelOrder.res
│   │   │   ├── StateViewSlice/
│   │   │   │   └── OrdersView.res
│   │   │   ├── AutomationSlice/
│   │   │   │   └── AutoShipOrder.res
│   │   │   └── OutboundTranslationSlice/
│   │   │       └── SendOrderConfirmation.res
│   │   ├── CatalogProduct/
│   │   │   ├── StateChangeSlice/
│   │   │   │   └── SyncCatalogProduct.res
│   │   │   └── StateViewSlice/
│   │   │       └── AvailableProductsView.res
│   │   ├── Extension/
│   │   │   └── ProductsExtension.res     # Inbound: catalog sync → DCB command
│   │   ├── ExtensionPoint/
│   │   │   └── OrdersExtensionPointMapping.res  # Outbound: DCB events → EP
│   │   └── Service/
│   │       └── EmailService.res
│   ├── tests/
│   │   ├── Customer/
│   │   │   └── CustomerBehaviorTest.res
│   │   ├── Order/
│   │   │   └── OrderDecisionTest.res
│   │   └── E2E/
│   │       └── OrderingE2ETest.res
│   ├── rescript.json
│   └── package.json
└── online-shop-hybrid/
    ├── src/
    │   └── Main.res                      # Platform assembly
    ├── rescript.json
    └── package.json
```

### 6.2 Key Implementation Differences from Existing Examples

**CatalogPlugin.res (hybrid composition):**

```rescript
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // --- Aggregate-based: Category ---
  module CategoryAggregate = Platform.Aggregate.Make(Category)
  module CategoryReadModel = Platform.ReadModel.Make(CategoriesReadModel)

  // --- DCB-based: Product + ProductDemand ---
  module CatalogEventLogMaker = Platform.DcbEventLog.Make(CatalogEventLog)
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName)
  // ... more slices
  module ProductsViewSlice = Platform.StateViewSlice.Make(ProductsView)
  module ProductDemandViewSlice = Platform.StateViewSlice.Make(ProductDemandView)
  module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct)

  // --- Extension Points and Extensions (same pattern) ---
  module ProductsExtensionPointMaker = Platform.ExtensionPoint.Make(...)
  module OrdersExtensionMaker = Platform.Extension.Make(...)

  module DcbSpec = {
    @schema type event = CatalogEventLog.event
    let stateChangeSlices = [module(AddProductSlice), ...]
    let stateViewSlices = [module(ProductsViewSlice), module(ProductDemandViewSlice)]
    let automationSlices = []
    let outboundTranslationSlices = []
    let inboundTranslationSlices = [module(ImportProductSlice)]
  }

  let make = (~scheduler, ~api, ~apiRole) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~version="1.0.0",
      ~heartbeatInterval=60,
      ~aggregates=[module(CategoryAggregate)],           // Aggregate
      ~readModels=[module(CategoryReadModel)],           // Aggregate read model
      ~dcbSpec=module(DcbSpec),                           // DCB slices
      ~extensionPoints=[module(ProductsExtensionPointMaker)],
      ~extensions=[module(OrdersExtensionMaker)],
      ~api, ~apiRole, ~scheduler,
    )
}
```

**CatalogEventLog.res (DCB events — excludes Category):**

```rescript
@schema
type event =
  | ProductAdded({productId: @s.matches(DcbTag.string) string, name: string, description: string, price: float})
  | ProductNameChanged({productId: @s.matches(DcbTag.string) string, name: string})
  | ProductDescriptionChanged({productId: @s.matches(DcbTag.string) string, description: string})
  | ProductPriceChanged({productId: @s.matches(DcbTag.string) string, price: float})
  | ProductDemandRecorded({productId: @s.matches(DcbTag.string) string, orderId: string})
  | ProductDemandRevoked({productId: @s.matches(DcbTag.string) string, orderId: string})
```

Note: Category events are NOT in this log — they live in the Category aggregate's own EventLog.

**PlaceOrder.res (cross-entity decision model):**

```rescript
type decisionModel = {
  orderExists: bool,
  availableProducts: Map.t<string, bool>,  // productId → exists and available
}

let initialDecisionModel = {orderExists: false, availableProducts: Map.make()}

let reduce = (model, event) =>
  switch event {
  | OrderPlaced(_) => {...model, orderExists: true}
  | CatalogProductSynced({productId, _}) =>
    {...model, availableProducts: model.availableProducts->Map.set(productId, true)}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | PlaceOrder({orderId, customerId, productIds}) =>
    if model.orderExists {
      Ok([])  // Idempotent
    } else {
      let unavailable = productIds->Array.filter(pid =>
        model.availableProducts->Map.get(pid) != Some(true)
      )
      if unavailable->Array.length > 0 {
        Error(ProductsNotAvailable(unavailable))
      } else {
        Ok([OrderPlaced({orderId, customerId, productIds})])
      }
    }
  }
```

This decision model spans Order AND CatalogProduct events — something impossible in the aggregate approach without querying a read model.

### 6.3 Files That Can Be Reused Directly

From **online-shop-aggregates**:
- `Category.res`, `CategoryBehavior.res` — aggregate spec and behavior (unchanged)
- `CategoriesReadModel.res`, `CategoriesProjections.res` — aggregate read model
- `Customer.res`, `CustomerBehavior.res` — aggregate spec and behavior
- `CustomersReadModel.res`, `CustomersProjections.res` — aggregate read model
- `EmailService.res` — external service stub
- `catalog-spec/ProductsExtensionPoint.res` — extension point spec
- `ordering-spec/OrdersExtensionPoint.res` — extension point spec

From **online-shop-dcb**:
- `AddProduct.res`, `ChangeProduct*.res` — StateChangeSlices
- `ProductsView.res`, `ProductDemandView.res` — StateViewSlices
- `ImportProduct.res` — InboundTranslationSlice
- `ShipOrder.res`, `CancelOrder.res` — StateChangeSlices
- `OrdersView.res`, `AvailableProductsView.res` — StateViewSlices
- `AutoShipOrder.res` — AutomationSlice
- `SendOrderConfirmation.res` — OutboundTranslationSlice
- `SyncCatalogProduct.res` — StateChangeSlice
- `RecordProductDemand.res` — StateChangeSlice

**New or modified files:**
- `CatalogPlugin.res` — hybrid composition (new)
- `OrderingPlugin.res` — hybrid composition (new)
- `CatalogEventLog.res` — reduced event set (no Category events)
- `OrderingEventLog.res` — reduced event set (no Customer events)
- `PlaceOrder.res` — enhanced decision model with product validation (modified)
- `ProductsExtensionPointMapping.res` — maps DCB events to EP (same as DCB example)
- `OrdersExtensionPointMapping.res` — maps DCB events to EP (same as DCB example)
- `Main.res` — platform assembly (new)
- All `package.json` and `rescript.json` files — new packages

### 6.4 Monorepo Integration

Add to `lerna.json` and root `package.json` workspaces:
```
examples/online-shop-hybrid/*
```

Package names following existing convention:
- `@reventlessdev/online-shop-hybrid-catalog-spec`
- `@reventlessdev/online-shop-hybrid-ordering-spec`
- `@reventlessdev/online-shop-hybrid-catalog`
- `@reventlessdev/online-shop-hybrid-ordering`
- `@reventlessdev/online-shop-hybrid`

---

## 7. Comparison: All Three Approaches

| Aspect | Aggregates | DCB | Hybrid |
|--------|-----------|-----|--------|
| Category modeling | Aggregate (own log) | Shared DCB log | Aggregate (own log) |
| Product modeling | Aggregate (own log) | Shared DCB log | DCB (shared with demand) |
| ProductDemand modeling | Separate aggregate + extension sync | DCB slice (same log as Product) | DCB slice (same log as Product) |
| Customer modeling | Aggregate (own log) | Shared DCB log | Aggregate (own log) |
| Order modeling | Aggregate (own log) | Shared DCB log | DCB (shared with CatalogProduct) |
| CatalogProduct (shadow) | Shadow aggregate + extension | DCB slice (same log as Order) | DCB slice (same log as Order) |
| Order → Product validation | Not possible at command time | Via shared decision model | Via shared decision model |
| Product → Demand validation | Not possible (separate logs) | Via shared decision model | Via shared decision model |
| Event log noise | None (isolated logs) | All entity events in one log | Minimal (only related entities share) |
| Component count (Catalog) | 3 aggregates + 3 read models | 8 slices + 3 views | 1 aggregate + 1 read model + 5 slices + 2 views |
| Component count (Ordering) | 3 aggregates + 3 read models | 8 slices + 2 views + 1 automation + 1 outbound | 1 aggregate + 1 read model + 4 slices + 2 views + 1 automation + 1 outbound |
| Cross-plugin communication | Extension points (identical) | Extension points (identical) | Extension points (identical) |
| Extension point source | Aggregate EventTopic | DCB EventTopic | Mixed: aggregate or DCB EventTopic |

### Key Takeaway

The hybrid approach gives each entity the **most appropriate modeling strategy**:

- **Independent entities** (Category, Customer) stay as aggregates — simple, isolated, no unnecessary event log sharing
- **Interdependent entities** (Product + Demand, Order + CatalogProduct) share a DCB event log — enabling cross-entity decision models without shadow aggregates or eventual consistency gaps
- **Cross-plugin boundaries** remain unchanged — extension points abstract away whether the source is an aggregate or DCB slice

---

## 8. Risks and Considerations

### 8.1 Cognitive Complexity

Developers must understand both approaches and know when to use which. The hybrid adds a decision point: "should this entity be an aggregate or a DCB slice?" Mitigation: clear guidelines in the platform-and-plugin guide and this example as reference.

### 8.2 Extension Point Mapping

Extension point mappings must handle events from DCB event logs when the source entity uses DCB. The existing `ExtensionPointMapping` pattern works identically for both — it maps domain events to extension point events regardless of storage origin. No special handling needed.

### 8.3 Testing

Tests must cover:
- Aggregate components work independently (standard aggregate tests)
- DCB slices work independently (standard decision model tests)
- **Both coexist in the same plugin** without interference (E2E tests)
- Extension points correctly bridge from both aggregate events and DCB events

### 8.4 No Cross-Storage Decisions

An aggregate cannot participate in a DCB decision model, and a DCB slice cannot replay aggregate events. If you discover that an aggregate entity needs to participate in a DCB decision, move it to the DCB log. The hybrid boundary must be clean: entities that need cross-entity consistency MUST share the same DCB log.

---

## 9. Conclusion

The hybrid approach is not a compromise — it is the **most architecturally precise** option. It applies each modeling strategy where it fits best:

1. **Aggregates for isolated entities** — no overhead from shared event logs, clean per-entity streams, simple state machines
2. **DCB for interdependent entities** — cross-entity validation at command time, shared event streams for related entities, no shadow aggregates needed
3. **Extension points for cross-plugin boundaries** — unchanged from either pure approach

The framework already supports this combination. Creating the `online-shop-hybrid` example requires no framework changes — only new plugin composition code that passes both `~aggregates` and `~dcbSpec` to `Plugin.make`. The example would serve as a reference for teams deciding how to model their own domains.
