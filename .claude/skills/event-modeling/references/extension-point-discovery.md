# Extension Point Discovery

## Identifying Cross-Boundary Event Flows

Extension points emerge where events from one bounded context are needed by another. In Event Modeling, these appear as **dependencies crossing context boundaries**.

## Discovery Process

### 1. Find Cross-Context Dependencies

In Event Modeling JSON, look for slices whose `dependencies` reference elements in a different `context`:

```
Slice: "Place Order" (context: Ordering)
  depends on: ProductAdded (context: Catalog) — INBOUND dependency
```

This means Ordering needs to know about Catalog products → Catalog should expose a `ProductsExtensionPoint`.

### 2. Identify the Publisher

The context that **produces** the events is the publisher. It defines the extension point spec:

```
Publisher: Catalog
ExtensionPoint: "Catalog.Products"
Events: ProductBecameAvailable, ProductPriceChanged
```

### 3. Identify the Subscriber

The context that **consumes** the events is the subscriber. It defines an extension:

```
Subscriber: Ordering
Extension: subscribes to "Catalog.Products"
Routes:
  ProductBecameAvailable → SyncCatalogProduct command
  ProductPriceChanged → ChangeSyncedPrice command
```

### 4. Design the Public API

The extension point events should be **stable public facts**, not internal implementation details:

| Internal Event | Public EP Event | Why Different |
|---------------|-----------------|--------------|
| `ProductAdded({name, description, price, sku, category})` | `ProductBecameAvailable({productId, name, price})` | Only externally relevant fields |
| `ProductPriceChanged({price, previousPrice, reason})` | `ProductPriceChanged({productId, price})` | Hide internal details |

### 5. Create Spec Package

The extension point types go in a separate spec package to avoid circular dependencies:

```
catalog-spec/
└── src/
    └── ProductsExtensionPoint.res  # types only, no behavior
```

Both the publisher (Catalog) and subscriber (Ordering) depend on this spec package.

## Common Patterns

### One-Way Data Sync

```
Catalog publishes: ProductBecameAvailable
Ordering subscribes: creates local SyncCatalogProduct
```

The subscriber creates a local copy of the data it needs — extension-driven aggregate (aggregate approach) or StateChangeSlice (DCB approach).

### Event Notification

```
Ordering publishes: ItemOrdered({productId, orderId})
Catalog subscribes: records demand via RecordProductDemand
```

The subscriber uses the event to trigger its own domain logic.

### Bidirectional (Rare)

Both contexts publish extension points and subscribe to each other. This is valid but should be carefully designed to avoid circular data flows.

## Output Format

For each discovered extension point:

```
ExtensionPoint:
  name: "Context.EntityName"
  publisher: ContextName (plugin)
  events: [PublicEvent1, PublicEvent2]
  subscribers:
    - context: OtherContext
      routes:
        - PublicEvent1 → LocalCommand1
        - PublicEvent2 → LocalCommand2
```
