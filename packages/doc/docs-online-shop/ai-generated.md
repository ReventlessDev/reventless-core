---
title: AI-Generated Walkthrough
sidebar_position: 5
---

# AI-Generated Walkthrough

This walkthrough shows what happens when you tell an AI assistant:

> "Create an online shop with a Catalog plugin (DCB) and an Ordering plugin (DCB). The Catalog has Products and Categories. Ordering has Customers and Orders. Catalog exposes product availability to Ordering. When an order is placed, auto-ship after 24 hours and send a confirmation email."

## What the AI Does

### Phase 1: Requirements Analysis

The AI identifies:

- **2 plugins:** Catalog, Ordering
- **4 entities:** Product, Category (Catalog); Customer, Order (Ordering)
- **Architecture:** DCB for both (stated preference)
- **Extension points:** Catalog.Products → Ordering subscribes
- **Automation:** AutoShipOrder (trigger: OrderPlaced, resolution: OrderShipped)
- **Outbound translation:** SendOrderConfirmation (email on OrderPlaced)

### Phase 2: Architecture Decision

For each entity, the AI evaluates against the decision guide:

| Entity | Cross-Entity? | Sync? | Automation? | Decision |
|--------|--------------|-------|-------------|----------|
| Product | No | No | No | DCB (user preference) |
| Category | No | No | No | DCB (user preference) |
| Customer | No | No | No | DCB |
| Order | Yes (checks products) | No | Yes (auto-ship) | DCB |
| CatalogProduct (Ordering) | — | Yes (from Catalog EP) | — | DCB (sync entity) |

### Phase 3: Code Generation

The AI generates 30+ files across 5 packages:

**catalog-spec/** — 1 file: `ProductsExtensionPoint.res`

**ordering-spec/** — 1 file: `OrdersExtensionPoint.res`

**catalog/** — 12+ files:
- StateChangeSlices: AddProduct, ChangeProductName, ChangeProductPrice, AddCategory, RenameCategory, ArchiveCategory
- StateViewSlices: ProductsView, CategoriesView
- ExtensionPoint: ProductsExtensionPointMapping
- Extension: OrdersExtension (subscribes to Ordering's EP)
- Plugin: CatalogPlugin

**ordering/** — 15+ files:
- StateChangeSlices: RegisterCustomer, PlaceOrder, ShipOrder, CancelOrder, SyncCatalogProduct
- StateViewSlices: CustomersView, OrdersView, AvailableProductsView
- AutomationSlice: AutoShipOrder
- OutboundTranslationSlice: SendOrderConfirmation
- Extension: ProductsExtension (subscribes to Catalog's EP)
- ExtensionPoint: OrdersExtensionPointMapping
- Plugin: OrderingPlugin

**online-shop/** — 1 file: `Main.res`

### Phase 4: Build and Verify

```bash
npm install
npm run build    # zero warnings
npm test         # all tests pass
```

## The Result

Running `node src/Main.res.mjs` starts:

- **GraphQL API** on port 4000 — all commands and queries available
- **MCP server** on port 3001 — AI agents can discover and use all tools/resources
- **Admin API** on port 4001/4002 — platform administration

The AI-generated code is identical in structure to the hand-written [DCB-based example](/online-shop/dcb-based) in this documentation.
