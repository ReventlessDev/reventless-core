# Plan: Update Documentation for Hybrid Online Shop Example

**Depends on**: [Implement online-shop-hybrid Example](./online-shop-hybrid-example.md)

## Goal

Update the Online Shop example documentation to cover the hybrid approach alongside the existing aggregate and DCB documentation. This includes:

1. Updating the overview page (`get-started.md`) to mention the hybrid approach
2. Creating a new documentation page (`hybrid-based.md`) describing the hybrid implementation
3. Adding a sidebar category for the hybrid plugin

---

## Step 1: Update Overview Page (`get-started.md`)

File: `packages/doc/docs-online-shop/get-started.md`

### 1.1 Update the Implementations table

- [x] Add a third row to the "Implementations" table at the bottom of the page:

```markdown
| [Hybrid](./hybrid-based) | Mixed — aggregates for independent entities, DCB for interdependent entities | Per entity type | Best of both — isolated streams where simple, cross-entity decisions where needed |
```

### 1.2 Add a section explaining the hybrid approach

- [x] Add a new section after the "Comparing the Two Approaches" section, before the "Automation and Integration Components" table:

Title: **"Combining Both Approaches"**

Content should cover:
- The framework supports both `~aggregates` and `~dcbSpec` in the same `Plugin.make` call
- When to use which: independent entities as aggregates, interdependent entities as DCB
- In this example: Category and Customer stay as aggregates; Product/ProductDemand and Order/CatalogProduct share DCB event logs
- Cross-plugin communication via extension points is identical regardless of internal modeling choice

### 1.3 Update the "Comparing the Two Approaches" table

- [x] Add a third column "Hybrid" to the comparison table, showing the mixed characteristics:

| Aspect | Aggregate-Based | DCB-Based | Hybrid |
|---|---|---|---|
| Event storage | One log per aggregate instance | Single shared log per Plugin | Both: per-aggregate logs + shared DCB log |
| Consistency boundary | Per aggregate instance | Per command (optimistic) | Per entity type — aggregate or optimistic |
| Cross-entity consistency | Not directly supported | Supported | Supported for DCB entities only |
| State for decisions | Full aggregate state | Minimal decisionModel | Both patterns coexist |
| Infrastructure footprint | More event log tables | Fewer tables | Middle ground |

### 1.4 Update the "Automation and Integration Components" table

- [x] Add a fourth column "Hybrid" showing which component type each feature uses:

| Feature | Aggregate-Based | DCB-Based | Hybrid |
|---|---|---|---|
| Auto-Ship Order | EventMapper | AutomationSlice | AutomationSlice (DCB) |
| Import Product | Task (S3) | InboundTranslationSlice | InboundTranslationSlice (DCB) |
| Send Order Email | SideEffectHandler | OutboundTranslationSlice | OutboundTranslationSlice (DCB) |

---

## Step 2: Create Hybrid Documentation Page

File: `packages/doc/docs-online-shop/hybrid-based.md`

### 2.1 Page structure

- [x] Create `packages/doc/docs-online-shop/hybrid-based.md` with frontmatter:

```yaml
---
title: Hybrid Implementation
sidebar_position: 4
---
```

### 2.2 Introduction

- [x] Write an introduction explaining the hybrid approach:
  - Mixes aggregate-based and DCB-based components within a single plugin
  - Each entity gets the modeling strategy that fits best
  - Independent entities (Category, Customer) use aggregates — simple, isolated event streams
  - Interdependent entities (Product + ProductDemand, Order + CatalogProduct) share a DCB event log — enabling cross-entity decision models

### 2.3 Catalog Plugin (Hybrid)

Document the Catalog plugin structure showing both the aggregate and DCB parts:

- [x] **Aggregate: Category** — describe the aggregate with commands/events table (same as aggregate-based page)
- [x] **Chapter: Product** — describe StateChangeSlices and StateViewSlices (same as DCB-based page)
- [x] **Chapter: ProductDemand** — describe the demand tracking DCB slice
- [x] **Why Category is an aggregate**: Category has no relationship to Product/Demand events. Including it in the DCB log would add noise without benefit. Its simple Add/Rename/Archive lifecycle is a natural fit for an isolated aggregate.
- [x] **Why Product + Demand share DCB**: ProductDemand uses the same `productId` tag as Product events. The ProductDemandView can query both in a single filtered read. The RecordProductDemand decision model can validate product existence.
- [x] **CatalogEventLog.res**: Show the DCB event type with only Product + Demand events (no Category events)
- [x] **Extension Point and Extension**: Same pattern as DCB page

### 2.4 Ordering Plugin (Hybrid)

- [x] **Aggregate: Customer** — describe the aggregate with commands/events table
- [x] **Chapter: Order** — describe StateChangeSlices, AutomationSlice, OutboundTranslationSlice
- [x] **Chapter: CatalogProduct** — describe the sync slice
- [x] **Why Customer is an aggregate**: Customer lifecycle is fully independent. No cross-entity consistency with Order/CatalogProduct needed.
- [x] **Why Order + CatalogProduct share DCB**: The PlaceOrder decision model can validate product availability by replaying CatalogProductSynced events — atomic cross-entity consistency without read model queries.
- [x] **OrderingEventLog.res**: Show the DCB event type with only Order + CatalogProduct events (no Customer events)
- [x] **PlaceOrder cross-entity validation**: Show and explain the enhanced decision model that checks product availability

### 2.5 Plugin Composition (key section)

This is the most important section — it shows the hybrid `Plugin.make` call:

- [x] **CatalogPlugin.res walkthrough**: Show the full composition code with annotations:
  - Aggregate section: `Platform.Aggregate.Make(Category, CategoryBehavior, ...)`, `Platform.ReadModel.Make(...)`
  - DCB section: `Platform.DcbEventLog.Make(CatalogEventLog)`, all slice `Make` calls
  - DcbSpec module bundling all slices
  - `Plugin.make` call with both `~aggregates=[...]` and `~dcbSpec=module(DcbSpec)` and `~readModels=[...]`
- [x] **OrderingPlugin.res walkthrough**: Same pattern for Ordering

### 2.6 Cross-Plugin Integration

- [x] Brief section noting that cross-plugin communication is identical to the other implementations
- [x] Note that extension points abstract away whether the source entity uses an aggregate or DCB internally — the EP contract is the same

### 2.7 When to Choose Hybrid

- [x] Comparison with the other two approaches — a decision guide:
  - Use **aggregate-based** when all entities are independent
  - Use **DCB-based** when all entities benefit from shared event log
  - Use **hybrid** when some entities are independent and others need cross-entity consistency
  - The hybrid boundary must be clean: entities that need cross-entity consistency MUST share the same DCB log

---

## Step 3: Update Sidebar Configuration

File: `packages/doc/sidebars-online-shop.js`

- [x] Add the hybrid-based page to the sidebar, after the DCB entry:

```javascript
const sidebars = {
  onlineShopSidebar: [
    'get-started',
    {
      type: 'doc',
      id: 'aggregate-based',
      label: 'Aggregate based plugin',
    },
    {
      type: 'doc',
      id: 'dcb-based',
      label: 'DCB based plugin',
    },
    {
      type: 'doc',
      id: 'hybrid-based',
      label: 'Hybrid plugin',
    },
    {
      type: 'category',
      label: 'Catalog',
      link: {
        type: 'generated-index',
        description: 'The Catalog bounded context — product listings and categories.',
      },
      items: [],
    },
    {
      type: 'category',
      label: 'Ordering',
      link: {
        type: 'generated-index',
        description: 'The Ordering bounded context — customers and orders.',
      },
      items: [],
    },
  ],
};
```

---

## Step 4: Build and Verify Documentation

- [x] Run `cd packages/doc && npm run build` — verify the Docusaurus site builds without errors
- [x] Run `cd packages/doc && npm run start` — verify the new page renders correctly
- [x] Verify sidebar navigation: get-started → Aggregate → DCB → Hybrid → Catalog → Ordering
- [x] Verify all internal links work (from get-started to hybrid-based and back)
- [x] Verify the hybrid page follows the same structure and depth as the aggregate and DCB pages

---

## Writing Guidelines

The hybrid page should follow the same conventions as the existing aggregate-based and DCB-based pages:

- **Tables** for commands/events/read models — same format
- **Code blocks** with file name comments (`// CatalogPlugin.res`)
- **Inline explanations** after code blocks
- **No D2 diagrams** unless the existing pages have them (they don't)
- **Same heading hierarchy**: Plugin → Aggregate/Chapter → Component tables → Implementation walkthrough
- **Highlight differences**: Call out explicitly what differs from the pure approaches (the `Plugin.make` call, the reduced event logs, the cross-entity decision model)
- **Keep it practical**: Focus on the "what" and "why", not abstract theory

## File Summary

### New Files
- `packages/doc/docs-online-shop/hybrid-based.md` — hybrid implementation documentation page

### Modified Files
- `packages/doc/docs-online-shop/get-started.md` — add hybrid to overview, comparison tables, implementations list
- `packages/doc/sidebars-online-shop.js` — add hybrid entry to sidebar
