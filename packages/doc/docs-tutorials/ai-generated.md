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

**catalog-spec/** — 1 file: `Products_ExtensionPoint.res`

**ordering-spec/** — 1 file: `Orders_ExtensionPoint.res`

**catalog/** — each component is split into a spec file (`@@reventless.spec`) and a body file (`_Behavior.res` / `_Projection.res`):
- StateChangeSlices: AddProduct, ChangeProductName, ChangeProductDescription, ChangeProductPrice, AddCategory, RenameCategory, ArchiveCategory (each `+ _Behavior.res`)
- StateViewSlices: Products, Categories (each `+ _Projection.res`)
- ExtensionPoint: ExtensionPoint/Products_ExtensionPointMapping.res
- Extension: Extension/Orders_Extension.res (subscribes to Ordering's EP)
- `Plugin.res` (generated — "AUTO-GENERATED — do not edit")

**ordering/** — same spec + body split:
- StateChangeSlices: RegisterCustomer, ChangeEmail, ChangeAddress, DeactivateCustomer, PlaceOrder, ShipOrder, CancelOrder, SyncCatalogProduct (each `+ _Behavior.res`)
- StateViewSlices: Customers, Orders, AvailableProducts (each `+ _Projection.res`)
- AutomationSlice: AutoShipOrder (`+ _Automation.res`)
- OutboundTranslationSlice: SendOrderConfirmation (`+ _Translation.res`)
- Extension: Extension/Products_Extension.res (subscribes to Catalog's EP)
- ExtensionPoint: ExtensionPoint/Orders_ExtensionPointMapping.res
- `Plugin.res` (generated)

**platform-in-memory/** — 1 file: `src/Main.res`

### Phase 4: Build and Verify

```bash
pnpm install
pnpm run build   # zero warnings
pnpm test        # all tests pass
```

The build runs `generate-plugin src/` (via each plugin's `prebuild` script) to
produce the `Plugin.res` composition root from the discovered components, then
compiles with ReScript.

## The Result

Running `node src/Main.res.mjs` from the `platform-in-memory` package starts:

- **GraphQL API** on port 4000 — all commands and queries available
- **MCP server** on port 3001 — AI agents can discover and use all tools/resources
- **Admin API** on port 4001/4002 — platform administration

The AI-generated code is identical in structure to the hand-written [DCB-based example](/tutorials/dcb-based) in this documentation.
