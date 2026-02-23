---
title: Get Started
sidebar_position: 1
---

# Online Shop Example

A simple, educational event-sourced application covering two bounded contexts.

## Overview

The **Online Shop** domain is universally familiar and maps cleanly onto event sourcing concepts. It features two bounded contexts — **Catalog** and **Ordering** — with two aggregates each, illustrating different aggregate lifecycles and cross-context integration by ID.

## Why This Domain Works Well

| Property | Reason |
|---|---|
| Universal familiarity | Everyone understands an online shop |
| Clear aggregate lifecycles | Each aggregate has obvious, distinct state transitions |
| Cross-context reference | `Order` references `Product.id` — integration by ID |
| Different event shapes | `Category` is reference-like; `Order` is transactional |
| No saga required | Contexts are loosely coupled — good for a first example |

---

## Bounded Context 1: Catalog

Manages the product catalogue — what is available for sale and how it is organized.

### Aggregate: `Product`

A product listing with name, description, and price.

| Commands | Events |
|---|---|
| `AddProduct` | `ProductAdded` |
| `UpdateName` | `NameUpdated` |
| `UpdateDescription` | `DescriptionUpdated` |
| `UpdatePrice` | `PriceUpdated` |

### Aggregate: `Category`

A named grouping of products (e.g. "Books", "Electronics"). `Product` aggregates reference a `CategoryId`.

| Commands | Events |
|---|---|
| `AddCategory` | `CategoryAdded` |
| `RenameCategory` | `CategoryRenamed` |
| `ArchiveCategory` | `CategoryArchived` |

---

## Bounded Context 2: Ordering

Handles the purchase flow — who is buying and what they ordered.

### Aggregate: `Customer`

A registered buyer with contact details and account status.

| Commands | Events |
|---|---|
| `RegisterCustomer` | `CustomerRegistered` |
| `UpdateEmail` | `EmailUpdated` |
| `UpdateAddress` | `AddressUpdated` |
| `DeactivateCustomer` | `CustomerDeactivated` |

### Aggregate: `Order`

A confirmed purchase referencing `Product` IDs and a `CustomerId`. Clear, linear lifecycle.

| Commands | Events |
|---|---|
| `PlaceOrder` | `OrderPlaced` |
| `ShipOrder` | `OrderShipped` |
| `CancelOrder` | `OrderCancelled` |

---

## Cross-Context Integration

`Order` references products by `ProductId` — integration by ID, not by object. This demonstrates the standard event-sourcing pattern for cross-context references without tight coupling between bounded contexts.
