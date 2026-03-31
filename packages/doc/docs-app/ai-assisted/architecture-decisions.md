---
title: Architecture Decisions
sidebar_position: 4
---

# How the AI Chooses Architecture

Before generating code, the AI evaluates each entity against the [Aggregate vs DCB Decision Guide](/app/aggregate-vs-dcb-decision-guide) to determine the right architecture.

## Decision Flow

```
Does the command need state from multiple entity types?
  ├─ Yes → DCB
  └─ No
      │
      Does the entity have a self-contained lifecycle?
        ├─ Yes → Aggregate
        └─ No (e.g., sync-only, reactive)
            │
            Is it part of a plugin that already uses DCB?
              ├─ Yes → DCB (add as another slice)
              └─ No → Consider DCB or extension-driven Aggregate
```

## When You'll See Each

### Aggregate

- Entity has a clear lifecycle (create → modify → close)
- Commands only need the entity's own state
- No cross-entity consistency requirements
- Example: `Category` — adding, renaming, and archiving only depend on the category itself

### DCB (Dynamic Consistency Boundary)

- Commands need state from multiple entities
- Entity exists to sync data from another plugin
- Automation or translation slices are needed
- Example: `PlaceOrder` — must verify all referenced products exist

### Hybrid

- Mix of both in one plugin
- Independent entities as aggregates, interdependent ones as DCB
- Example: `Category` as aggregate + `Product`/`ProductDemand` as DCB in the same Catalog plugin

## Overriding the AI's Choice

You can specify your preference directly:

> "Create the Catalog plugin using DCB for all entities."

> "Use aggregates for Products — they're self-contained in our domain."

The AI will follow your preference but may note trade-offs if the choice conflicts with the decision criteria.

## Design Summary

Before generating code, the AI presents a summary like:

```
Plugin: Catalog
Architecture: DCB

Entities:
  Product:
    Commands: AddProduct, ChangeProductName, ChangeProductPrice
    Events: ProductAdded, ProductNameChanged, ProductPriceChanged
    Views: ProductsView

Extension Points:
  Catalog.Products:
    Events: ProductBecameAvailable, ProductPriceChanged
```

Confirm or adjust this before code generation begins.
