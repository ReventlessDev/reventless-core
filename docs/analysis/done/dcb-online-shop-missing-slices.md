# Analysis: DCB Online Shop — AutomationSlice, InboundTranslationSlice, OutboundTranslationSlice Ideas

## Context

The DCB online shop example currently demonstrates **StateChangeSlice** (write-side decisions) and **StateViewSlice** (read-side projections) across two plugins — Catalog and Ordering. It also shows cross-plugin communication via Extension Points and Extensions.

Three slice types are **not yet represented** in the example:

- **AutomationSlice** — event-driven TODO list that issues internal commands
- **InboundTranslationSlice** — receives external input, translates to domain commands
- **OutboundTranslationSlice** — reacts to events by calling external services

This analysis proposes concrete, easy-to-understand ideas for each, grounded in the existing domain model.

---

## Existing Domain Summary

### Catalog Events
`ProductAdded`, `ProductNameChanged`, `ProductDescriptionChanged`, `ProductPriceChanged`, `CategoryAdded`, `CategoryRenamed`, `CategoryArchived`, `ProductDemandRecorded`, `ProductDemandRevoked`

### Ordering Events
`CustomerRegistered`, `EmailChanged`, `AddressChanged`, `CustomerDeactivated`, `OrderPlaced`, `OrderShipped`, `OrderCancelled`, `CatalogProductSynced`, `CatalogProductPriceChanged`

---

## AutomationSlice Ideas

An AutomationSlice listens to events, builds a TODO list of pending work, processes each item by issuing a command, and marks items resolved when a completion event arrives. It is purely internal — no external service calls.

### Idea 1: Auto-Ship Order (Ordering Plugin)

**Trigger**: `OrderPlaced` → creates TODO item
**Process**: Issues a `ShipOrder` command (targeting the order's StateChangeSlice)
**Resolve**: `OrderShipped` → marks the item complete

**Why it's good**: This is the canonical automation example from the docs. It closes a clear loop (placed → shipped) and requires adding only one new StateChangeSlice (`ShipOrder`) plus the automation. In a real system the "process" step might check inventory or wait for payment, but for the example it can auto-ship immediately.

**New events needed**: None — `OrderShipped` already exists.
**New StateChangeSlice needed**: `ShipOrder` (accepts `ShipOrder` command, checks order exists and isn't already shipped, emits `OrderShipped`).

**Complexity**: Very low. The collect/resolve/process functions are each 3–5 lines.

### Idea 2: Archive Empty Category (Catalog Plugin)

**Trigger**: `ProductDemandRevoked` → creates TODO item keyed by category ID (would need a small event log extension to include `categoryId`, or alternatively trigger on a hypothetical `ProductRemovedFromCategory` event)
**Process**: Issues an `ArchiveCategory` command
**Resolve**: `CategoryArchived` → marks the item complete

**Why it's good**: Shows automation in the Catalog context. However, it requires either extending the event model or adding a lookup mechanism, which adds complexity.

**Complexity**: Medium. Requires event model changes.

### Idea 3: Send Welcome Discount on Registration (Ordering Plugin)

**Trigger**: `CustomerRegistered` → creates TODO item with `{customerId, email}`
**Process**: Issues a `PlaceWelcomeOrder` command (a special zero-cost order with a welcome gift)
**Resolve**: `OrderPlaced` with a matching welcome marker → marks item complete

**Why it's good**: Demonstrates a cross-concern automation within a single plugin. But the "welcome order" concept is a bit contrived.

**Complexity**: Medium. Needs a way to distinguish welcome orders from regular orders.

### Recommendation

**Idea 1 (Auto-Ship Order)** is the clear winner. It uses existing events, requires minimal new code, and the automation loop (placed → ship command → shipped) is immediately understandable. It directly mirrors the example in the AutomationSlice documentation.

---

## InboundTranslationSlice Ideas

An InboundTranslationSlice receives external JSON input (e.g., from a webhook), validates and translates it into a domain command. It is synchronous — no external calls, just input parsing and mapping.

### Idea 1: Import Product from Supplier Feed (Catalog Plugin)

**External input**: JSON payload from a supplier system: `{sku, title, desc, unitPrice, currency}`
**Translate**: Maps supplier fields to domain fields — `sku` → `productId`, `title` → `name`, `unitPrice` converted from cents to dollars, currency validated
**Command**: `AddProduct({productId, name, description, price})`
**Error cases**: Missing SKU, unsupported currency, negative price

**Why it's good**: Product import is a universally understood concept. The anti-corruption layer does real work — field renaming, unit conversion, validation — making the translation function non-trivial but still simple. Uses the existing `AddProduct` StateChangeSlice with no changes.

**New code needed**: Just the InboundTranslationSlice spec file (~30 lines).

**Complexity**: Very low.

### Idea 2: Receive External Order (Ordering Plugin)

**External input**: JSON from a marketplace integration: `{externalOrderId, buyerEmail, buyerAddress, items: [{sku, qty}]}`
**Translate**: Validates the buyer exists or creates a composite ID, maps `items` to `productIds`, generates an `orderId`
**Command**: First `RegisterCustomer` (if new), then `PlaceOrder({orderId, customerId, productIds})`
**Error cases**: Empty items list, unknown SKUs

**Why it's good**: Marketplace order ingestion is relatable. However, needing to potentially issue two commands (register + place order) doesn't fit the single-command return type of `translate`. Would need to simplify to assume customer already exists.

**Complexity**: Medium (if simplified to single command) to High (if handling customer creation).

### Idea 3: Bulk Price Update from ERP (Catalog Plugin)

**External input**: JSON from an ERP system: `{productCode, newPrice, effectiveDate, reason}`
**Translate**: Maps `productCode` → `productId`, validates price > 0, ignores future-dated updates
**Command**: `ChangeProductPrice({productId, price})`
**Error cases**: Unknown product code format, zero/negative price, future effective date

**Why it's good**: ERP integration is a common real-world scenario. The validation logic (date checking, price validation) makes the translate function interesting. Uses existing `ChangeProductPrice` StateChangeSlice.

**Complexity**: Very low.

### Recommendation

**Idea 1 (Import Product from Supplier Feed)** is the best choice. The field-renaming and unit-conversion in the translate function clearly demonstrate the anti-corruption layer concept. It pairs naturally with the Catalog plugin and reuses the existing `AddProduct` command. **Idea 3 (Bulk Price Update)** is a strong alternative and could be added alongside Idea 1 to show two inbound translations in the same plugin with minimal extra effort.

---

## OutboundTranslationSlice Ideas

An OutboundTranslationSlice listens to events, collects outbound work items, and calls an external service for each. It can optionally publish a command back into the domain. The `translate` function is async.

### Idea 1: Send Order Confirmation Email (Ordering Plugin)

**Trigger**: `OrderPlaced` → collects `{orderId, customerId}` (email could be looked up or included)
**Translate**: Calls an email service API to send a confirmation email. Fire-and-forget (`Ok(None)`).
**Error**: Email service down → retry

**Why it's good**: Email notifications are the most universally understood side effect. Everyone knows "order placed → send email." The fire-and-forget pattern (`inboundCommand = unit`) is the simplest outbound translation. Since this is an example, the actual email call can be a mock/stub.

**New events needed**: None — `OrderPlaced` already exists.
**New code needed**: Just the OutboundTranslationSlice spec file (~25 lines) + a stub `EmailService` module.

**Complexity**: Very low.

### Idea 2: Notify Warehouse on Order (Ordering Plugin)

**Trigger**: `OrderPlaced` → collects `{orderId, productIds}`
**Translate**: Calls a warehouse API to create a pick list. Returns `Ok(Some(orderId, WarehouseAcknowledged({orderId, warehouseRef})))` — command-back pattern.
**Error**: Warehouse API unavailable → retry

**Why it's good**: Demonstrates the command-back pattern where the external call result feeds back into the domain. This is more interesting than fire-and-forget because it shows the full outbound loop. Requires a new event (`WarehouseAcknowledged`) and a StateChangeSlice to handle it.

**Complexity**: Medium. Needs new event + StateChangeSlice for the acknowledgment.

### Idea 3: Sync Product to Search Index (Catalog Plugin)

**Trigger**: `ProductAdded`, `ProductNameChanged`, `ProductDescriptionChanged`, `ProductPriceChanged` → collects `{productId, ...latest fields}`
**Translate**: Calls a search/indexing API (e.g., Algolia, Elasticsearch) to upsert the product. Fire-and-forget.
**Error**: Search service unavailable → retry

**Why it's good**: Search index sync is a well-known pattern. It demonstrates collecting from multiple event types into the same outbound item type. The collect function has multiple match arms, showing richer event filtering. However, since collect only gets the event (not the current state), the outbound item would only contain the changed field — which makes the "upsert" less clean unless you collect the full product on `ProductAdded` and partial updates on change events.

**Complexity**: Low to Medium. Multiple collect arms but straightforward translate.

### Recommendation

**Idea 1 (Send Order Confirmation Email)** is the best starting point — minimal, immediately understandable, and demonstrates the fire-and-forget pattern cleanly. If a second outbound translation is desired, **Idea 2 (Notify Warehouse)** is a great complement because it demonstrates the command-back pattern. Together they show both return paths (`Ok(None)` and `Ok(Some(...))`).

---

## Summary of Recommendations

| Slice Type | Recommended Idea | Plugin | Complexity | New Events | New StateChangeSlice |
|---|---|---|---|---|---|
| **AutomationSlice** | Auto-Ship Order | Ordering | Very Low | None | `ShipOrder` |
| **InboundTranslationSlice** | Import Product from Supplier | Catalog | Very Low | None | None (reuses `AddProduct`) |
| **OutboundTranslationSlice** | Send Order Confirmation Email | Ordering | Very Low | None | None |

All three recommendations:
- Use **existing events** from the current domain model (no event log changes)
- Require **minimal new code** (one spec file each, ~25–35 lines)
- Are **immediately understandable** to anyone familiar with e-commerce
- Each lives in a **different plugin** (2 Ordering, 1 Catalog), showing that these patterns apply across the whole system
- Together they cover all three slice types with the simplest possible variant of each

### Optional Additions (for a richer example)

If more depth is desired, these could be added alongside the primary recommendations:

1. **Bulk Price Update from ERP** (InboundTranslationSlice, Catalog) — second inbound translation showing validation-heavy anti-corruption
2. **Notify Warehouse** (OutboundTranslationSlice, Ordering) — demonstrates the command-back pattern (`Ok(Some(...))`) as a contrast to the fire-and-forget email
