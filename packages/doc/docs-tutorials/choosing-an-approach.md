---
title: Choosing an approach
---

# Choosing an approach: Aggregate, DCB, or Hybrid

The online shop is implemented three times — once with each plugin style. Before
following the walkthrough, it helps to know which style you would reach for, and
why this tutorial uses the **Hybrid** one.

## The three styles in one table

| | Aggregate-based | DCB-based | Hybrid |
|---|---|---|---|
| Event storage | One event log per aggregate instance | One shared, tag-filtered log per plugin | Both — per-aggregate logs **and** a shared DCB log |
| Consistency boundary | Per aggregate instance | Per command (optimistic) | Per entity type |
| Cross-entity decisions | Not directly supported | Supported (slices read across entities) | Supported for the DCB entities |
| Best when | Entity lifecycles are independent | You need consistency across entities in one command | Some entities are independent, others are interdependent |

## How to decide, per entity

For each entity in your plugin, ask:

1. **Does its decision need to see other entities' events?** → DCB.
2. **Does a read model need to combine its events with another entity's events?**
   → both entities should share a DCB log.
3. **Is its lifecycle fully independent?** → Aggregate.

If every entity points the same way, use that pure style. If the answers are
mixed — which is common — use **Hybrid**, modelling each entity with the
approach that fits it. The full reasoning lives in the App Guide's
[DCB concepts](/app/concepts/dcb).

## Why this tutorial uses Hybrid

The shop has both kinds of entity:

- **Independent** — `Customer` is a self-contained lifecycle: registering,
  updating contact details, deactivating and reactivating. No other entity's
  events take part in those decisions → aggregate.
- **Interdependent** — `Category`, `Product`, `ProductDemand`, `Order`, and
  `CatalogProduct` all decide on events other entities produced. `AddProduct`
  reads `CategoryAdded` / `CategoryArchived` to reject a product in a category
  that does not exist or has been withdrawn; `PlaceOrder` reads
  `CatalogProductSynced` to reject an order for a product Ordering has never
  heard of. Those reads only work if the entities share a tag-filtered log → DCB.

Note how the rule plays out for `Category`: on its own it is a plain
Add/Rename/Archive lifecycle and would make a perfectly good aggregate. It is DCB
here because *another* entity's decision has to read its events — the question is
never "is this entity simple?" but "does any decision need to see it alongside
something else?".

Hybrid is the most representative of a real application, so it is the spine of
this tutorial. The two pure styles are kept as
[alternates](#alternate-implementations) for comparison.

## Alternate implementations

- [Aggregate-based](./aggregate-based) — every entity as an aggregate.
- [DCB-based](./dcb-based) — every entity in one shared DCB log.

---

**Next:** walk through the recommended implementation in the
[Hybrid walkthrough →](./hybrid-based)
