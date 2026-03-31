# Bounded Context Discovery

## From Event Models to Plugins

Each bounded context in an Event Model becomes a Reventless **plugin**. Identifying context boundaries is the first step in translating an Event Model to Reventless code.

## Discovery Rules

### 1. Explicit Context Labels

If the Event Model uses `context` fields (e.g., in EM JSON), group slices by context name:

```
context: "Catalog" → CatalogPlugin
context: "Ordering" → OrderingPlugin
context: "Shipping" → ShippingPlugin
```

### 2. Entity Clustering

When contexts aren't labeled, cluster by entity affinity:

- Slices operating on the same entity belong together
- Slices with shared events belong together
- Slices with `idAttribute` fields referencing the same entity type belong together

### 3. Cohesion Test

A bounded context should be **cohesive** — its slices share a common domain language and entity model. Signs of a context boundary:

- **Language shift:** "Product" means different things (catalog product vs order line item)
- **Lifecycle independence:** Entities can be created/modified without the other context
- **Team ownership:** Different teams would own different sets of slices

### 4. Autonomy Test

Each plugin should be deployable independently:

- Can this context function if the other context is down? (eventual consistency is OK)
- Does this context need synchronous access to the other's data? (if yes, maybe same context)

## Output

For each discovered bounded context, produce:

```
Plugin: {ContextName}
  Entities: [{entity1}, {entity2}, ...]
  StateChangeSlices: [{slice1}, {slice2}, ...]
  StateViewSlices: [{view1}, {view2}, ...]
  AutomationSlices: [{automation1}, ...]
  ExtensionPoints: [{ep1}, ...] (events crossing this boundary)
  Extensions: [{ext1}, ...] (subscribing to other contexts)
```

This output feeds directly into the `reventless-app` skill for code generation.
