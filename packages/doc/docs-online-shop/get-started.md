---
title: Overview
sidebar_position: 1
---

# Online Shop Example

A simple, educational event-sourced application covering two Plugins.

## Overview

The **Online Shop** domain is universally familiar and maps cleanly onto event sourcing concepts. It features two Plugins — **Catalog** and **Ordering** — illustrating different domain lifecycles and cross-context integration by ID.

## Why This Domain Works Well

| Property | Reason |
|---|---|
| Universal familiarity | Everyone understands an online shop |
| Clear domain lifecycles | Each concept has obvious, distinct state transitions |
| Cross-context reference | `Order` references `Product.id` — integration by ID |
| Different event shapes | `Category` is reference-like; `Order` is transactional |
| No saga required | Plugins are loosely coupled — good for a first example |

---

## Plugin 1: Catalog

Manages the product catalogue — what is available for sale and how it is organized.

**Catalog Items** are product listings with a name, description, and lifecycle (active or archived). **Categories** are named groupings (e.g. "Books", "Electronics") that catalog items can reference.

## Plugin 2: Ordering

Handles the purchase flow — who is buying and what they ordered.

**Customers** are registered buyers with contact details and account status. **Orders** are confirmed purchases referencing product IDs and a customer ID, with a clear linear lifecycle from placement to shipping or cancellation.

## Cross-Plugin Integration

`Order` references products by `ProductId` — integration by ID, not by object. This demonstrates the standard event-sourcing pattern for cross-plugin references without tight coupling between Plugins.

---

## Implementations

The same domain is implemented twice — once using each core Reventless plugin style:

| Implementation | Plugin Style | Consistency | Best For |
|---|---|---|---|
| [Aggregate-Based](./aggregate-based) | One event log per aggregate instance | Per aggregate instance | Traditional DDD, isolated entity lifecycles |
| [DCB-Based](./dcb-based) | Single shared event log with tag-filtered reads | Per command (optimistic) | Cross-entity consistency, simpler infrastructure |

Both implementations cover the **Catalog** Plugin and serve as a concrete reference for comparing the two approaches side by side.

---

## Comparing the Two Approaches

| Aspect | Aggregate-Based | DCB-Based |
|---|---|---|
| Event storage | One log per aggregate instance | Single shared log per Plugin |
| Consistency boundary | Per aggregate instance (sequential) | Per command (optimistic concurrency) |
| State for decisions | Full aggregate state | Minimal `decisionModel` per slice |
| Cross-entity consistency | Not directly supported | Supported — slices can read across items |
| Read model wiring | Separate projection mapping modules | `project` function inline in the slice |
| Infrastructure footprint | More event log tables | Fewer tables, more events per table |

Choose the aggregate-based approach when entity lifecycles are independent and you want the simplest possible consistency model. Choose DCB when you need consistency across multiple entities in the same command, or when you want to avoid the overhead of per-instance event streams.
