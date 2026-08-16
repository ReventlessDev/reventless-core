---
title: AI-Generated Walkthrough
---

# AI-Generated Walkthrough

This walkthrough shows what happens when you tell an AI assistant:

> "Create an online shop with a Catalog plugin (DCB) and an Ordering plugin (DCB). The Catalog has Products and Categories. Ordering has Customers and Orders. Catalog exposes product availability to Ordering. When an order is placed, ship it automatically and send a confirmation email."

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

**platform-local/** — 1 file: `src/Main.res`

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

Running `node src/Main.res.mjs` from the `platform-local` package starts:

- **The domain GraphQL API** on port 4000 — every command and query
- **The domain MCP server** on port 3001 — the same surface for AI assistants
- **The platform admin API** on port 4001, with its MCP server on 3002

The generated code is identical in structure to the hand-written
[DCB-based example](/tutorials/dcb-based) in this documentation — the assistant
is not producing a different kind of application, only producing the same kind
faster.

## Doing it yourself

This page describes the output. For the workflow — the slash commands, what to
say to get a good result, and how to grow an existing project — see
[AI-assisted development](/app/ai-assisted/).
