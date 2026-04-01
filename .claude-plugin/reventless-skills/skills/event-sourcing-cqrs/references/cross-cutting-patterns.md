# Cross-Cutting Patterns

## Extension Points — Cross-Plugin Communication

Plugins are isolated bounded contexts. They never depend on each other directly. Communication flows through **extension points**:

```
Plugin A (Publisher)
  → maps internal events to stable public API
  → publishes via ExtensionPoint

Plugin B (Subscriber)
  → subscribes via Extension
  → maps public API events to local commands
```

### Why Extension Points?

- **Decoupling:** Plugins can evolve independently
- **Stable API:** Public event types are versioned separately from internal types
- **Direction:** Publisher doesn't know who subscribes; subscriber doesn't know publisher internals
- **Spec packages:** Shared type definitions live in separate packages, breaking circular dependencies

### Extension Point Spec

Defines the public API between plugins:

```
name: "Catalog.Products"
command: unit (read-only — no inbound commands)
event: ProductBecameAvailable | ProductPriceChanged
directive: unit
```

### Extension

Subscribes to another plugin's extension point and routes incoming events to local commands:

```
Incoming: ProductBecameAvailable({productId, name, price})
→ Route to: SyncCatalogProduct({productId, name, price})
```

## Side Effects — External System Integration

Fire-and-forget handlers that react to events by calling external systems:

```
Event: OrderPlaced({orderId, customerId})
→ Side Effect: send confirmation email to customer
```

Key properties:
- **Read-only:** Can query read models but cannot produce events
- **At-least-once:** May be invoked multiple times (design for idempotency)
- **No return value:** Fire and forget — errors are logged, not propagated

In Reventless: `SideEffectHandler` (aggregate approach)

## Automation — Event-Driven Command Generation

Reacts to events by generating new commands automatically:

```
Event: OrderPlaced({orderId})
→ Automation: after 24 hours, if not cancelled, generate ShipOrder({orderId})
```

Key properties:
- **TODO list pattern:** Events create work items; resolution events complete them
- **Idempotent:** Processing the same work item twice should be safe
- **Retryable:** Failed processing retries with backoff
- **Heartbeat-driven:** Periodic check for pending work items

In Reventless: `AutomationSlice` (DCB approach), `EventMapper` (aggregate approach)

## Translation — Anti-Corruption Layers

### Inbound Translation

Converts external data formats into domain commands:

```
External: {sku: "X100", title: "Laptop", unitPrice: 99900, currency: "USD"}
→ Validate: currency must be USD, price must be positive
→ Translate to: AddProduct({productId: "X100", name: "Laptop", price: 999.00})
```

Key properties:
- **Validation:** Rejects invalid external input before it enters the domain
- **Format conversion:** Maps external field names/types to domain types
- **Boundary protection:** Prevents external system quirks from leaking into the domain

In Reventless: `InboundTranslationSlice` (DCB approach), `Task` (aggregate approach)

### Outbound Translation

Reacts to events by calling external systems with translated data:

```
Event: OrderPlaced({orderId, customerId})
→ Collect: {orderId, customerId}
→ Translate: call EmailService.sendConfirmation(email, orderId)
→ Optionally: echo back a command confirming the call
```

Key properties:
- **Retryable:** Failed calls retry with configurable max retries
- **Heartbeat-driven:** Periodic retry of pending outbound items
- **Optional echo:** Can produce an inbound command confirming the external call

In Reventless: `OutboundTranslationSlice` (DCB approach), `SideEffectHandler` (aggregate approach)

## Future: Sagas / Process Managers

Sagas coordinate multi-aggregate workflows by listening to events and issuing compensating commands:

```
OrderPlaced → ReserveInventory
InventoryReserved → ChargePayment
PaymentFailed → ReleaseInventory (compensating action)
```

Sagas are a known ES/CQRS pattern but are **not yet implemented** in Reventless. The current alternatives are:
- `AutomationSlice` for single-step autonomous workflows
- `EventMapper` for aggregate-to-aggregate event routing
- `ExtensionPoint`/`Extension` for cross-plugin coordination

A dedicated Saga component type may be added in future framework versions.
