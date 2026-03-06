# Analysis: Aggregates Online Shop — EventMapper, SideEffectHandler, and Task Ideas

## Context

The aggregates-based online shop example currently demonstrates **Aggregates** (with behaviors), **ReadModels** (with projections), **Extension Points**, and **Extensions** across two plugins — Catalog and Ordering.

Three component types are **not yet represented** in the example:

- **EventMapper** — maps events from source aggregates to commands on a target aggregate (saga/process manager patterns)
- **SideEffectHandler** — reacts to events by calling external services (fire-and-forget)
- **Task** — file-based or scheduled processing triggered by S3 uploads or cron schedules

This analysis proposes concrete, easy-to-understand ideas for each, grounded in the existing domain model. The ideas intentionally mirror those proposed for the DCB online shop example (see `dcb-online-shop-missing-slices.md`) to allow readers to compare the aggregate-based and DCB-based approaches side by side.

---

## Existing Domain Summary

### Catalog Plugin — Aggregates
- **Product**: commands `Add`, `UpdateName`, `UpdateDescription`, `UpdatePrice`; events `Added`, `NameUpdated`, `DescriptionUpdated`, `PriceUpdated`
- **Category**: commands `Add`, `Rename`, `Archive`; events `Added`, `Renamed`, `Archived`
- **ProductDemand**: commands `Record`, `Revoke`; events `Recorded`, `Revoked`

### Ordering Plugin — Aggregates
- **Order**: commands `Place`, `Ship`, `Cancel`; events `Placed`, `Shipped`, `Cancelled`
- **Customer**: commands `Register`, `UpdateEmail`, `UpdateAddress`, `Deactivate`; events `Registered`, `EmailUpdated`, `AddressUpdated`, `Deactivated`
- **CatalogProduct**: commands `Sync`, `UpdatePrice`; events `Synced`, `PriceUpdated` (shadow copy)

### Cross-Plugin Communication
- Catalog → Ordering: `ProductsExtensionPoint` (`ProductBecameAvailable`, `ProductPriceChanged`)
- Ordering → Catalog: `OrdersExtensionPoint` (`ItemOrdered`, `ItemOrderCancelled`)

### Currently Not Used
All aggregates use `NoEventMappings` — no EventMappers or SideEffectHandlers exist in the example.

---

## EventMapper Ideas

An EventMapper listens to events from one or more source aggregates and publishes commands to a target aggregate. It enables cross-aggregate coordination within a plugin (sagas, process managers, reactive logic).

### Idea 1: Auto-Ship Order (Ordering Plugin)

**Source**: Order aggregate — listens to `Order.Placed`
**Target**: Order aggregate — publishes `Order.Ship` command
**Mapping**: When an order is placed, automatically issue a `Ship` command for that order

```
Order.Placed → EventMapper → Order.Ship
```

**Why it's good**: This is the simplest possible EventMapper — a single event-to-command mapping within the same aggregate. It mirrors the AutomationSlice idea from the DCB analysis, letting readers compare the stateless EventMapper approach (fire-and-forget, no TODO list) with the stateful AutomationSlice approach (TODO tracking, resolution, retry). The Order aggregate already has the `Ship` command and `Shipped` event, so no aggregate changes are needed.

**New code needed**: One `Order_EventMappings.res` file (~15 lines) replacing the current `NoEventMappings`.

**Complexity**: Very low.

### Idea 2: Deactivate Customer on All Orders Cancelled (Ordering Plugin)

**Source**: Order aggregate — listens to `Order.Cancelled`
**Target**: Customer aggregate — publishes `Customer.Deactivate` command
**Mapping**: When an order is cancelled, check (via QueryEngine) if the customer has any remaining active orders. If none remain, deactivate the customer.

```
Order.Cancelled → QueryEngine lookup → Customer.Deactivate (conditional)
```

**Why it's good**: Demonstrates the `PublishAsync` pattern — the mapper queries the `OrdersReadModel` to make a conditional decision. Shows cross-aggregate coordination within a plugin. However, the business logic ("cancel all orders → deactivate customer") is somewhat contrived.

**Complexity**: Medium. Requires async query + conditional logic.

### Idea 3: Record Demand When Order Placed (Intra-Plugin, Catalog)

**Source**: This would require listening to Order events within the Catalog plugin, which is already handled by the Extension Point/Extension mechanism. Not a good fit for EventMapper since it crosses plugin boundaries.

**Complexity**: N/A — already solved by extensions.

### Recommendation

**Idea 1 (Auto-Ship Order)** is the clear winner. It's the simplest possible EventMapper, uses existing commands/events, and directly parallels the DCB AutomationSlice idea. This makes it ideal for comparing the two architectural approaches: aggregate EventMapper (stateless, no tracking) vs. DCB AutomationSlice (stateful TODO list with resolution).

---

## SideEffectHandler Ideas

A SideEffectHandler listens to events and performs external side effects (API calls, notifications, webhooks) without publishing commands back into the domain. It is fire-and-forget.

### Idea 1: Send Order Confirmation Email (Ordering Plugin)

**Source**: Order aggregate — listens to `Order.Placed`
**Effect**: Calls an email service to send a confirmation email to the customer
**QueryEngine**: Looks up the customer's email from the `CustomersReadModel`

```
Order.Placed → QueryEngine(CustomersReadModel) → EmailService.send(...)
```

**Why it's good**: Email notifications are the most universally understood side effect. This mirrors the OutboundTranslationSlice idea from the DCB analysis, letting readers compare: SideEffectHandler (fire-and-forget, no retry tracking, no TODO list) vs. OutboundTranslationSlice (TODO list with per-item retry and status tracking). Since this is an example, the email call can be a stub/mock.

**New code needed**: One `Order_EmailNotification.res` file (~20 lines) + a stub `EmailService` module.

**Complexity**: Very low.

### Idea 2: Send Shipping Notification (Ordering Plugin)

**Source**: Order aggregate — listens to `Order.Shipped`
**Effect**: Sends a "your order has shipped" notification

**Why it's good**: Natural companion to Idea 1 — shows multiple event arms in the same SideEffectHandler. However, it doesn't add much conceptual value beyond Idea 1.

**Complexity**: Very low (but adds minimal new insight).

### Idea 3: Notify External Inventory System (Ordering Plugin)

**Source**: Order aggregate — listens to `Order.Placed` and `Order.Cancelled`
**Effect**: Calls an external warehouse/inventory API to reserve or release stock

```
Order.Placed → WarehouseAPI.reserveStock(productIds)
Order.Cancelled → WarehouseAPI.releaseStock(productIds)
```

**Why it's good**: Demonstrates a SideEffectHandler with multiple event arms that calls a business-critical external system. More realistic than email but still easy to understand. Shows the limitation of fire-and-forget — if the warehouse call fails, there's no built-in retry tracking (unlike OutboundTranslationSlice).

**Complexity**: Low.

### Recommendation

**Idea 1 (Send Order Confirmation Email)** is the best starting point — minimal, immediately understandable, and directly comparable to the DCB OutboundTranslationSlice idea. If a richer example is desired, **Idea 3 (Notify External Inventory)** could be added alongside to show a more business-critical side effect with multiple event arms.

---

## Task Ideas

A Task handles file-based processing (S3 uploads) or scheduled jobs. It can publish commands to aggregates, create/delete schedules, and include its own SideEffectHandlers. Tasks are unique to the aggregate-based architecture — the DCB approach uses InboundTranslationSlice for similar external input scenarios.

### Idea 1: Import Products from CSV (Catalog Plugin)

**Trigger**: CSV file uploaded to an S3 bucket
**Processing**: Parse the CSV, extract product rows, publish `Product.Add` commands for each row
**Actions**: `PublishCommands("Product", [...])` for each valid row

```
S3 upload (products.csv) → parse rows → Product.Add commands
```

**Why it's good**: CSV import is universally understood in e-commerce. It demonstrates the core Task pattern — file triggers a Lambda that publishes domain commands. It mirrors the InboundTranslationSlice idea from the DCB analysis (Import Product from Supplier Feed) but uses the file-based Task mechanism instead of a webhook-triggered translation. The callback function does real work — CSV parsing, field validation, unit conversion — making it non-trivial but still simple.

**New code needed**: One Task module (~30 lines) + a simple CSV parsing utility (or use `rescript-fast-csv` which already exists in the repo).

**Complexity**: Low.

### Idea 2: Export Orders Report (Ordering Plugin)

**Trigger**: Scheduled (e.g., daily at midnight)
**Processing**: Query the `OrdersReadModel`, generate a CSV/JSON summary, upload to an S3 bucket
**Actions**: `CreateSchedule(Daily(0, 0))` to set up recurring execution

```
Schedule (daily) → QueryEngine(OrdersReadModel) → generate report → S3 upload
```

**Why it's good**: Shows the scheduled Task pattern (no S3 trigger, uses cron instead). Demonstrates the QueryEngine integration for reading from read models. However, it requires writing to S3 which adds complexity beyond a simple example.

**Complexity**: Medium.

### Idea 3: Bulk Price Update from File (Catalog Plugin)

**Trigger**: JSON file uploaded to an S3 bucket containing `[{productId, newPrice}, ...]`
**Processing**: Parse the JSON, publish `Product.UpdatePrice` commands for each entry
**Actions**: `PublishCommands("Product", [...])` for each price update

```
S3 upload (prices.json) → parse entries → Product.UpdatePrice commands
```

**Why it's good**: Simpler than CSV parsing (JSON is native), directly comparable to the DCB InboundTranslationSlice "Bulk Price Update from ERP" idea. Uses existing `UpdatePrice` command with no aggregate changes.

**Complexity**: Very low.

### Recommendation

**Idea 1 (Import Products from CSV)** is the best choice. It demonstrates the full Task lifecycle — S3 trigger, file parsing, command publishing — and is the most natural "real-world" use case for file-based processing. It also leverages `rescript-fast-csv` which already exists in the monorepo. **Idea 3 (Bulk Price Update)** is a strong alternative if simplicity is prioritized over demonstrating CSV parsing.

---

## Summary of Recommendations

| Component Type | Recommended Idea | Plugin | Complexity | Aggregate Changes |
|---|---|---|---|---|
| **EventMapper** | Auto-Ship Order | Ordering | Very Low | None (reuses `Order.Ship`) |
| **SideEffectHandler** | Send Order Confirmation Email | Ordering | Very Low | None |
| **Task** | Import Products from CSV | Catalog | Low | None (reuses `Product.Add`) |

All three recommendations:
- Use **existing aggregate commands** (no spec or behavior changes needed)
- Require **minimal new code** (one module file each, 15–30 lines)
- Are **immediately understandable** to anyone familiar with e-commerce
- Live across **both plugins** (2 Ordering, 1 Catalog)
- **Mirror the DCB analysis** ideas, enabling side-by-side comparison of the two architectural approaches

### Comparison with DCB Equivalents

| Aggregate Component | DCB Equivalent | Key Difference |
|---|---|---|
| **EventMapper** (Auto-Ship Order) | **AutomationSlice** (Auto-Ship Order) | EventMapper is stateless fire-and-forget; AutomationSlice maintains a TODO list with resolution tracking and retry |
| **SideEffectHandler** (Send Email) | **OutboundTranslationSlice** (Send Email) | SideEffectHandler is fire-and-forget; OutboundTranslationSlice has per-item retry, status tracking, and optional command-back |
| **Task** (Import Products CSV) | **InboundTranslationSlice** (Import Product from Supplier) | Task is file-triggered (S3); InboundTranslationSlice is webhook/API-triggered with schema validation and audit log |

This comparison highlights the architectural trade-offs: aggregate-based components are simpler but offer less built-in reliability; DCB-based slices provide more operational guarantees at the cost of additional infrastructure.

### Optional Additions (for a richer example)

1. **Notify External Inventory** (SideEffectHandler, Ordering) — shows multiple event arms and a business-critical external call
2. **Bulk Price Update from JSON** (Task, Catalog) — simpler alternative to CSV import, closer parallel to the DCB ERP price update idea
3. **Daily Orders Export** (Task, Ordering) — demonstrates scheduled Tasks with QueryEngine integration
