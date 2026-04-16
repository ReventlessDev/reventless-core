# Reventless ↔ Event Modeling JSON Schema: Conversion Analysis

## 1. Overview

Martin Dilger (Nebulit / eventmodelers.de) created a JSON schema for Event Modeling, originally designed for his Miro-based Event Modeling Toolkit. The schema is published at [github.com/dilgerma/event-modeling-spec](https://github.com/dilgerma/event-modeling-spec) (`eventmodeling.schema.json`, JSON Schema Draft 07, MIT license). A CLI code generator ([embuilder-node](https://github.com/dilgerma/embuilder-node)) consumes this format.

### 1.1 Adoption and Standardization Status

**Dilger's schema is not a standard.** It has very low adoption (19 GitHub stars, 2 forks, single commit from 2025-10-17 — no subsequent development as of April 2026) and is used almost exclusively within Nebulit's own Miro toolkit and code generator. No other project was found that imports, validates against, or generates this schema. Adam Dymitruk's eventmodeling.org does not reference or endorse any JSON schema — the site is purely conceptual.

The companion CLI ([embuilder-node](https://github.com/dilgerma/embuilder-node)) is actively maintained (latest `0.1.52`, March 2026), but it is a template/prompt installer — the actual code generation runs in a closed Docker image (`nebulit/generators`) that is not publicly available. The schema file itself has had zero changes since its initial commit.

The event modeling community has **no agreed-upon interchange format**. The landscape is fragmented:

| Project | Format | Notes |
|---------|--------|-------|
| **dilgerma/event-modeling-spec** | JSON Schema (Draft 07) | Nebulit's Miro toolkit. 19 stars. Single commit (2025-10-17). No version field. |
| **SamHatoum/event-modeling-spec** | Zod/TypeScript → JSON Schema | Independent, unrelated schema with same repo name. 6 stars. |
| **err0r500/fairway-spec** | CUE language | DSL for vertical slices with validation rules. |
| **waiteperspectives/eml** | Custom DSL (Rust) | Text DSL compiled to SVG diagrams. 19 stars. |
| **lgazo/event-modeling-tools** | Custom `.evml` DSL | VS Code + Obsidian plugin, outputs SVG. 9 stars. |
| **chilit-nl/plantuml-event-modeling** | PlantUML macros | Library for event model diagrams. 42 stars. |
| **prooph board** | Proprietary JSON ("playshots") | SaaS platform with its own format, exports to Cody Engine. |

**Adjacent formats that do NOT overlap**:
- **AsyncAPI**: Runtime message API contracts — no design-time event modeling concepts (slices, commands vs. events, read models).
- **CloudEvents** (CNCF): Runtime wire format for event payloads — orthogonal to design-time modeling.
- **EventCatalog** (eventcatalog.dev): Documentation tool using markdown files to catalog existing events and services. Integrates with AsyncAPI/OpenAPI but does not model the event modeling methodology's flow (commands → events → read models).

**Implication for Reventless**: Since no standard exists, adopting Dilger's schema as an interchange format is pragmatic — it is the most complete attempt and its slice-centric structure aligns well with Reventless components. But the schema should be treated as one import/export option, not as a canonical format.

---

## 2. Schema Structure

The root object contains a single required property — an array of slices:

```json
{ "slices": [ { ... } ] }
```

Everything is organized around **vertical slices**, not aggregates or bounded contexts.

**Slice:**

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique slice identifier |
| `title` | string | Slice name |
| `sliceType` | enum | `STATE_CHANGE`, `STATE_VIEW`, `AUTOMATION` |
| `status` | enum | `Created`, `Done`, `InProgress` |
| `index` | integer | Ordering on the timeline |
| `context` | string | Swimlane / bounded context name |
| `commands` | Element[] | Command elements in this slice |
| `events` | Element[] | Event elements in this slice |
| `readmodels` | Element[] | Read model elements in this slice |
| `screens` | Element[] | UI wireframe elements |
| `processors` | Element[] | Automation/translation elements |
| `tables` | Table[] | Structured data views |
| `specifications` | Specification[] | Given/When/Then test scenarios |
| `actors` | Actor[] | Users/external systems (each has `name`, `authRequired`) |
| `aggregates` | string[] | Aggregate names referenced by this slice |
| `screenImages` | ScreenImage[] | UI mockup references (each has `id`, `title`, optional `url`) |

**Element** (shared type for commands, events, read models, screens, automations):

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique element identifier |
| `title` | string | Element name (e.g., "AddProduct", "ProductAdded") |
| `type` | enum | `COMMAND`, `EVENT`, `READMODEL`, `SCREEN`, `AUTOMATION` |
| `fields` | Field[] | Data attributes |
| `dependencies` | Dependency[] | Inbound/outbound links to other elements |
| `aggregate` | string | Which aggregate this belongs to |
| `modelContext` | string | Bounded context within the model |
| `context` | enum | `INTERNAL` or `EXTERNAL` |
| `description` | string | Free-text description |
| `createsAggregate` | boolean | Whether this command creates a new instance |
| `apiEndpoint` | string | API path |
| `service` | string | Service/microservice name |
| `tags` | string[] | Arbitrary tags |
| `groupId` | string | Visual grouping on the modeling board |
| `domain` | string | Domain assignment |
| `slice` | string | Back-reference to parent slice |
| `aggregateDependencies` | string[] | Other aggregates this element depends on |
| `triggers` | string[] | What triggers this element |
| `sketched` | boolean | Draft/work-in-progress marker |
| `prototype` | object | Feature flagging config (e.g., `activeByDefault`) |
| `listElement` | boolean | Whether a read model renders as a list |

**Field:**

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Field name |
| `type` | enum | `String`, `Boolean`, `Double`, `Decimal`, `Long`, `Custom`, `Date`, `DateTime`, `UUID`, `Int` |
| `subfields` | Field[] | Nested/complex types (recursive) |
| `example` | string/object | Example value (oneOf string or object) |
| `optional` | boolean | Whether the field is optional |
| `idAttribute` | boolean | Whether this is the identity field |
| `cardinality` | enum | `List` or `Single` |
| `generated` | boolean | Auto-generated field |
| `mapping` | string | Field mapping reference |
| `technicalAttribute` | boolean | Whether this is a technical (non-domain) field |
| `schema` | string | Schema reference |

**Dependency** (connections between elements):

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | ID of the target element |
| `type` | enum | `INBOUND` or `OUTBOUND` |
| `title` | string | Name of the connected element |
| `elementType` | enum | `EVENT`, `COMMAND`, `READMODEL`, `SCREEN`, `AUTOMATION` |

**Specification** (Given/When/Then):

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique spec identifier |
| `title` | string | Test scenario name |
| `linkedId` | string | Element under test |
| `given` | SpecificationStep[] | Precondition events |
| `when` | SpecificationStep[] | Command being tested |
| `then` | SpecificationStep[] | Expected outcome events/errors |
| `vertical` | boolean | Layout hint for visual rendering |
| `sliceName` | string | Name of the parent slice |
| `comments` | Comment[] | Free-text comments (each has `description`) |

**SpecificationStep:**

| Field | Type | Description |
|-------|------|-------------|
| `type` | enum | `SPEC_EVENT`, `SPEC_COMMAND`, `SPEC_READMODEL`, `SPEC_ERROR` |
| `title` | string | Step name |
| `fields` | Field[] | Data fields for this step |
| `tags` | string[] | Arbitrary tags |
| `examples` | object[] | Additional example data |
| `index` | integer | Ordering |
| `specRow` | integer | Row position in visual layout |
| `linkedId` | string | Linked element |
| `expectEmptyList` | boolean | Whether an empty result is expected |

### 2.1 Key Design Characteristics

1. **Flat element model**: Commands, events, read models, screens, and automations all share the same `Element` type — differentiated only by the `type` enum.
2. **Slice-centric**: No top-level aggregate or bounded context definitions — those are string references on slices and elements.
3. **Graph-based connections**: Elements carry `dependencies[]` with `INBOUND`/`OUTBOUND` direction, forming an explicit connection graph.
4. **Specifications are first-class**: Given/When/Then scenarios are built into the schema at the slice level.
5. **Visual-tool oriented**: Includes `screens`, `screenImages`, `actors`, `index` (timeline ordering), `sketched` flags — designed for visual Event Modeling tools, not code generation.

**Note on Reventless approaches**: Reventless supports three architectural approaches — **Aggregate** (traditional event-sourced aggregates with Behavior), **DCB** (Dynamic Consistency Boundary with StateChangeSlice/StateViewSlice/AutomationSlice/TranslationSlices), and **Hybrid** (mixing both in the same plugin). All three share the same `initialState/evolve/decide` naming convention. The JSON schema's slice-centric structure maps most naturally to the DCB approach.

**Note on chapters**: Martin Dilger uses "chapter" to mean structural grouping of slices on the board (a `timeline` node in the board backup format). This structural chapter concept is lost when exporting to code-generation JSON — the `sliceGroups` placeholder in `config.json` is never populated. See [Section 2.3](#23-chapters-structural-and-temporal) for full details including the temporal chapter concept ("Closing the Books"), which is unrelated to Dilger's usage and also absent from the schema.

### 2.2 Example: AddProduct Slice in JSON

```json
{
  "id": "slice-add-product",
  "title": "Add Product",
  "sliceType": "STATE_CHANGE",
  "status": "Done",
  "index": 1,
  "context": "Catalog",
  "aggregates": ["Product"],
  "commands": [
    {
      "id": "cmd-add-product",
      "title": "AddProduct",
      "type": "COMMAND",
      "aggregate": "Product",
      "createsAggregate": true,
      "fields": [
        { "name": "productId", "type": "UUID", "idAttribute": true },
        { "name": "name", "type": "String" },
        { "name": "description", "type": "String" },
        { "name": "price", "type": "Double" }
      ],
      "dependencies": [
        { "id": "evt-product-added", "type": "OUTBOUND", "title": "ProductAdded", "elementType": "EVENT" }
      ]
    }
  ],
  "events": [
    {
      "id": "evt-product-added",
      "title": "ProductAdded",
      "type": "EVENT",
      "aggregate": "Product",
      "fields": [
        { "name": "productId", "type": "UUID", "idAttribute": true },
        { "name": "name", "type": "String" },
        { "name": "description", "type": "String" },
        { "name": "price", "type": "Double" }
      ],
      "dependencies": [
        { "id": "cmd-add-product", "type": "INBOUND", "title": "AddProduct", "elementType": "COMMAND" }
      ]
    }
  ],
  "readmodels": [],
  "screens": [],
  "processors": [],
  "specifications": [
    {
      "id": "spec-add-product-new",
      "title": "Adding a new product succeeds",
      "linkedId": "cmd-add-product",
      "given": [],
      "when": [
        { "type": "SPEC_COMMAND", "title": "AddProduct", "fields": [
          { "name": "productId", "example": "prod-1" },
          { "name": "name", "example": "Widget" },
          { "name": "description", "example": "A fine widget" },
          { "name": "price", "example": "9.99" }
        ]}
      ],
      "then": [
        { "type": "SPEC_EVENT", "title": "ProductAdded", "fields": [
          { "name": "productId", "example": "prod-1" },
          { "name": "name", "example": "Widget" },
          { "name": "description", "example": "A fine widget" },
          { "name": "price", "example": "9.99" }
        ]}
      ]
    },
    {
      "id": "spec-add-product-duplicate",
      "title": "Adding a duplicate product fails",
      "linkedId": "cmd-add-product",
      "given": [
        { "type": "SPEC_EVENT", "title": "ProductAdded", "fields": [
          { "name": "productId", "example": "prod-1" }
        ]}
      ],
      "when": [
        { "type": "SPEC_COMMAND", "title": "AddProduct", "fields": [
          { "name": "productId", "example": "prod-1" }
        ]}
      ],
      "then": [
        { "type": "SPEC_ERROR", "title": "ProductAlreadyExists" }
      ]
    }
  ]
}
```

### 2.3 Chapters: Structural and Temporal

**Important clarification on terminology**: When Martin Dilger uses the word "chapter" in his YouTube videos and Nebulit documentation, he means it in the **structural** sense only — a named section of the event modeling board that groups related slices. He is **not** referring to the temporal "Closing the Books" pattern from event sourcing. See [chapters-in-event-modeling.md](chapters-in-event-modeling.md) for the full analysis of both chapter types.

#### Dilger's "Chapter" — What It Is and Where It Lives

In the Nebulit board tool, a chapter is a **named timeline frame** — the primary top-level container on the board. Each chapter is a grid with rows (actor lane, interaction lane, swimlane, spec lane) and columns (one per slice). It gives a section of the board a business-meaningful name like `"Checkout"` or `"Registration"`.

Technically it is a `timeline` node in the **internal board backup format** (`eventmodel-backup-*.json`):

```json
{
  "type": "timeline",
  "data": {
    "label": "Checkout",
    "rows": [
      { "type": "actor", "label": "Actor" },
      { "type": "interaction", "label": "Interaction" },
      { "type": "swimlane", "label": "Swimlane" },
      { "type": "spec", "label": "Spec Lane" }
    ],
    "columns": [ ... ],
    "cells": [ ... ]
  }
}
```

**Chapters do not survive into the code-generation JSON export.** The published `eventmodeling.schema.json` (the schema this document analyses) has no chapter field — the export format is a flat `slices[]` array. The companion `config.json` used by `embuilder-node` has a `sliceGroups: []` field that appears to be the placeholder for chapters, but it is always empty in practice across all published sample repos. The chapter grouping is currently lost at export time.

This means the gap is **in the tooling**, not in the concept. Dilger's chapters are structural — they just aren't serialized into the code-generation format yet.

#### Structural Chapters in Reventless

In Reventless, structural chapters map to **subfolders inside a plugin's `src/` directory** (`Category/`, `Product/`). The `generate-plugin` tool and `reventless-ppx` both use folder names to classify components, so folder structure is the primary expression of structural chapters in code.

Since `sliceGroups` is unused in the JSON, the only available hook for round-tripping chapter information is the **`context` field on slices** — a free-text, unconstrained string. It can encode the chapter name by convention:

**Import convention**: Parse `slice.context` for chapter grouping:
- Dotted (e.g., `"Catalog.Product"`) → plugin `Catalog`, subfolder `Product/`
- Simple (e.g., `"Catalog"`) → plugin `Catalog`, no subfolder

This produces the structural chapter folder hierarchy that `reventless-ppx` then uses to inject correct boilerplate (DCB tag annotations, `open Reventless.Projection` for StateViewSlice files, etc.).

**Export convention**: Write `"<PluginName>.<EntityGroupFolder>"` as the `context` (e.g., `catalog/src/Product/` → `"context": "Catalog.Product"`).

If/when `sliceGroups` in `config.json` is populated by the Nebulit tooling, that would be the correct field to use instead of encoding chapters into the `context` string.

#### Temporal Chapters ("Closing the Books")

Temporal chapters — where an entity's event stream is divided into bounded time periods with carry-forward summary events — are a separate event sourcing concept. **Dilger does not use "chapter" in this sense.** This pattern is entirely absent from the JSON schema and the Nebulit board format.

When translating from JSON, temporal chapters cannot be inferred. They must be added by the developer after import, selectively and only for long-lived entities with natural business lifecycle boundaries.

**Summary table**:

| Chapter Type | In Board Backup (`eventmodel-backup-*.json`) | In Code-Gen JSON (`eventmodeling.schema.json`) | Reventless Mapping | Import Strategy |
|---|---|---|---|---|
| **Structural (Dilger's "chapter")** | `timeline` node with `label` | Lost — `sliceGroups: []` placeholder unused | Subfolder in `src/` (e.g., `Product/`) | Use `slice.context` by convention |
| **Temporal ("Closing the Books")** | Not present | Not present | Optional `type summary` + `initFromSummary`/`toSummary` in Spec | Cannot be inferred — added manually post-import |

---

## 3. Gap Analysis: What Each Side Cannot Express

### 3.1 Reventless Concepts Missing from Event Modeling JSON

The JSON schema was designed for visual Event Modeling (the methodology), not for framework-specific code generation. The following Reventless concepts have no representation:

| Reventless Concept | Description | Impact |
|-------------------|-------------|--------|
| **Ephemeral state** (`state`, `initialState`) | Per-command state rebuilt from events to guard acceptance (both DCB slices and aggregate behaviors use the same naming) | Cannot generate the state type or its initial value |
| **Evolve function** (`evolve`) | Folds events into the ephemeral state | No way to express which events affect which state fields |
| **Decide function** (`decide`) | Pattern-matches on state + command → `Ok(events)` or `Error(error)` | No way to express the acceptance/rejection logic |
| **Produced / consumed event decoupling** (`producedEvent`, `consumedEvent`) | Each DCB slice declares its own produced and consumed event types — consumed events can be payload-less or partial projections | Events belong to individual slices, not a per-slice type pair |
| **Projection logic** (`project`) | How events map to read model state changes (Set, Update, Delete, etc.) | Read models exist as elements but their projection rules are opaque |
| **DCB tags** (`@s.matches(DcbTag.string)`) and auto-query (`DcbTag.buildQueryFromCommand`) | Content-based event filtering for Dynamic Consistency Boundaries; queries are auto-derived from command schema tags | No equivalent — `idAttribute` partially overlaps but serves a different purpose |
| **DCB validation** (`DcbValidation.validateProducedAndConsumed`) | Compile-time check that consumed event types are structurally compatible with produced event types across slices | No cross-element validation concept |
| **DCB decoding** (`DcbDecode`) | Runtime decoding of consumed events including payload-less variants and partial field projections | No partial decoding concept |
| **Shared event log** (DcbEventLog) | Single event log shared across all slices in a plugin | Events belong to individual slices, not a shared log |
| **Error types** as structured variants | Typed error variants with payloads (e.g., `ProductNotFound`) | Only `SPEC_ERROR` in specifications — not type definitions |
| **Extension point protocol** | Formal EP with `command`, `event`, `directive` types | Dependencies link elements but have no EP/extension contract semantics |
| **Extension mapping** (`mapIncomingEvent`, `mapOutgoingEvent`) | How EP events translate to internal commands and vice versa | No mapping function concept |
| **Inbound translation** (`externalInput`, `translate`) | Anti-corruption layer: external input → `result<(id, command), string>` | No equivalent — `AUTOMATION` has no `translate` structure |
| **Outbound translation** (`outboundItem`, `inboundCommand`, `collect`, `translate`) | Tracked, retryable external service calls via TODO-list pattern; `translate` returns `promise<result<option<(id, inboundCommand)>, string>>` | No equivalent — `AUTOMATION` has no collect/translate structure |
| **Automation slice internals** (`collect`, `resolve`, `process`, `todoItem`) | TODO-list pattern with pending work tracking and heartbeat-driven sweep | `AUTOMATION` slice type exists but is structurally empty |
| **Plugin as deployment unit** | Plugin bundles aggregates/slices, EPs, extensions | No plugin concept — `context` is a flat string |
| **Platform composition** | Assembles plugins with version | No top-level composition |
| **Heartbeat interval** | Per-plugin polling configuration | No infrastructure config |
| **sury/schema annotations** | `@schema`, `@s.matches` for serialization | No serialization concept |
| **PPX-injected boilerplate** (`@@reventless.spec`, `@@reventless.behavior`) | Auto-injects `let name`, `module Id`, `let moduleUrl`, DCB tag annotations, `open Reventless.Projection` etc. based on folder/filename | No equivalent — the JSON has no concept of code generation conventions |
| **Folder-based structural chapters** | Slices grouped by entity subfolder (`Category/`, `Product/`) — recognized by `generate-plugin` and `reventless-ppx` | `slice.context` (free string) can encode this by convention, but is not structured |
| **Temporal chapters ("Closing the Books")** | Optional `type summary` + `initFromSummary`/`toSummary` in Aggregate.Spec or StateChangeSlice.Spec — carry-forward state across bounded time periods | Not present — no chapter boundaries, summary events, or lifecycle periods |
| **Api component** (GraphQL schema generation, stitching, MCP schema) | Auto-generated GraphQL API from read model schemas with fragment stitching | `apiEndpoint` exists but is a flat string, not a structured config |

### 3.2 Event Modeling JSON Concepts Missing from Reventless

The JSON schema captures visual modeling and specification concepts that Reventless does not:

| JSON Schema Concept | Description | Impact |
|--------------------|-------------|--------|
| **Given/When/Then specifications** | Structured test scenarios with example data per slice | Reventless tests exist as separate `.res` files — no structured spec format in the framework |
| **UI screens** (`screens[]`, `screenImages[]`) | Wireframe references linked to slices | Reventless is backend-only — no UI modeling |
| **Actors** (`actors[]` with `name`, `authRequired`) | Who triggers which commands | Reventless has Identity/RequestContext for auth but no actor/persona modeling concept |
| **Slice status** (`Created`, `InProgress`, `Done`) | Project management metadata | Reventless specs are either code or not — no workflow status |
| **Timeline ordering** (`index`) | Chronological narrative position | Reventless components are unordered — wiring determines flow |
| **Element grouping** (`groupId`) | Visual grouping on the modeling board | No equivalent |
| **Sketched flag** (`sketched`) | Draft/work-in-progress marker | No equivalent |
| **Service assignment** (`service`) | Which microservice owns this element | Reventless uses plugins, not microservices |
| **Prototype config** (`prototype.activeByDefault`) | Feature flagging for visual tool | No equivalent |
| **List element flag** (`listElement`) | Whether a read model renders as a list | No rendering concept |
| **Tables** (`tables[]` with fields) | Structured data views separate from read models | Reventless read models serve this purpose |
| **Comments** on specifications | Free-text comments on test scenarios | No equivalent |

### 3.3 Partial Overlaps

Some concepts exist in both but map imperfectly:

| Concept | Reventless | Event Modeling JSON | Gap |
|---------|-----------|--------------------|----|
| **Aggregate identity** | `module Id = Id.String` (abstract type) | `idAttribute: true` on a field | JSON marks which field is the ID; Reventless has a separate module-level identity type |
| **Aggregate grouping** | Plugin → aggregates array / dcbSpec | `slice.aggregates[]` strings + `element.aggregate` string | JSON uses flat string refs; Reventless uses typed module composition |
| **Bounded context / plugin** | Plugin name | `slice.context` / `element.modelContext` | 1:1 mapping possible but plugin carries more semantics (deployment unit, heartbeat, etc.) |
| **Structural chapter (entity group)** | Subfolder in `src/` (e.g., `Product/`, `Category/`) | `slice.context` dotted suffix (e.g., `"Catalog.Product"`) — by convention only | JSON has no structured grouping below the plugin/context level; the subfolder convention must be agreed externally |
| **Command → Event flow** | `decide` function (both aggregate Behavior and StateChangeSlice) | `dependencies[]` with INBOUND/OUTBOUND | JSON captures the connection but not the logic |
| **Event → ReadModel flow** | Projection Mapping / StateViewSlice `project` | `dependencies[]` from event to readmodel | JSON captures the connection but not the projection rules |
| **Cross-boundary communication** | ExtensionPoint + Extension with typed mapping | Elements with `context: "EXTERNAL"` + dependencies | JSON has no formal protocol — just "external" markers |
| **Field types** | Rich ReScript type system (`string`, `float`, `option<T>`, `array<T>`, records) | Limited enum (`String`, `Int`, `Double`, `UUID`, `Custom`) + `subfields` | `option`, variant types, and abstract types have no direct mapping |
| **Automation** | AutomationSlice with `collect`/`resolve`/`process`/`todoItem`, `maxRetries`, `heartbeatInterval` | `sliceType: "AUTOMATION"` with `processors[]` | JSON has the category but none of the internal structure |

---

## 4. Field Type Mapping

| ReScript Type | JSON Schema `type` | Bidirectional? | Notes |
|--------------|-------------------|----------------|-------|
| `string` | `String` | Yes | |
| `int` | `Int` | Yes | JSON also has `Long` for larger integers |
| `float` | `Double` | Yes | JSON also has `Decimal` for precise decimals |
| `bool` | `Boolean` | Yes | |
| `option<T>` | field with `optional: true` | Partial | ReScript `option` is richer (can be nested: `option<option<T>>`) |
| `array<T>` | field with `cardinality: "List"` | Partial | JSON doesn't support `array<array<T>>` or typed array elements |
| inline record `{...}` | field with `subfields[]` | Yes | Recursive nesting supported in both |
| named type ref | `type: "Custom"` | Partial | JSON loses the type identity — just a marker |
| variant type | No equivalent | No | JSON has no discriminated union concept |
| `Id.String.t` (abstract) | `type: "UUID"` + `idAttribute: true` | Partial | JSON marks identity but doesn't have abstract types |
| `Set.t<T>` | No equivalent | No | Non-serializable types in decision models |

---

## 5. Conversion Workflows

### 5.1 Reventless → Event Modeling JSON (export)

**Input**: ReScript source files (`.res`)
**Output**: Event Modeling JSON file

**Workflow**:

1. **Create slices from components**:
   - Each StateChangeSlice / Aggregate behavior → `STATE_CHANGE` slice
   - Each StateViewSlice / ReadModel → `STATE_VIEW` slice
   - Each AutomationSlice / OutboundTranslationSlice → `AUTOMATION` slice
   - InboundTranslationSlice → `STATE_CHANGE` slice (closest match — receives input, produces events)

2. **Map types to elements**:
   - Command variant → `Element` with `type: "COMMAND"`, fields from the variant's payload
   - Event variant → `Element` with `type: "EVENT"`
   - Read model / StateViewSlice state → `Element` with `type: "READMODEL"`
   - Mark commands that create new aggregates with `createsAggregate: true` (inferred from `initialState` and `decide` logic)

3. **Map field types**: `string` → `String`, `int` → `Int`, `float` → `Double`, `bool` → `Boolean`, `option<T>` → field with `optional: true`. Mark DCB-tagged fields with `idAttribute: true`.

4. **Build dependency graph**: For each command → event relationship (from `decide`), add `OUTBOUND` dependency on the command and `INBOUND` on the event. For projection mappings, add dependencies from events to read models.

5. **Map cross-plugin connections**: Extension point mappings → dependencies between elements with `context: "EXTERNAL"`.

6. **Set context with structural chapter encoding**: For each slice, set `context` as `"<PluginName>.<EntityGroupFolder>"` if the slice file lives under an entity-group subfolder (e.g., `src/Product/StateChangeSlice/AddProduct.res` → `"Catalog.Product"`). This encodes the structural chapter into the JSON so it round-trips correctly on reimport. If there is no entity-group subfolder, use the plugin name alone.

7. **Generate specifications** from test files if available (parse Jest test structure for Given/When/Then patterns), or leave `specifications: []`.

**Information lost in export**:

| Lost Concept | Workaround |
|-------------|------------|
| Ephemeral state + evolve/decide logic | None — not representable. Could add as `description` prose. |
| Projection mapping rules | None — read models appear but without mapping logic. |
| Aggregate behavioral state (initialState/evolve) | None — aggregate state machine is opaque. |
| Produced/consumed event decoupling (partial projections, payload-less variants) | None — JSON events are full-shape only. |
| Error types as structured variants | Partially recoverable from `SPEC_ERROR` in specifications. |
| DCB tags (beyond `idAttribute`) | Could use `tags[]` on fields for non-ID tagged fields, but this is non-standard. |
| Translation rules (inbound/outbound) | None — automation slices appear but without internal structure. |
| EP/Extension protocol and mappings | External dependencies capture connections but not the mapping functions. |
| Temporal chapters (summary events, carry-forward state) | None — no JSON representation exists. Chapter boundaries are a Reventless-only concern (see [chapters-in-event-modeling.md](chapters-in-event-modeling.md)). |

### 5.2 Event Modeling JSON → Reventless (import)

**Input**: Event Modeling JSON file (exported from Miro toolkit or embuilder)
**Output**: ReScript source files (`.res`)

**Workflow**:

1. **Group slices by context and structural chapter**: Parse `slice.context`:
   - If dotted (e.g., `"Catalog.Product"`): the first segment is the plugin name (`Catalog`), remaining segments form the subfolder path (`Product/`). This encodes a **structural chapter** — the entity-group folder that `generate-plugin` and `reventless-ppx` will use for boilerplate injection.
   - If undotted (e.g., `"Catalog"`): use as plugin name with no subfolder grouping.
   - Create one plugin package per unique first segment.

2. **Determine approach**: Default to DCB (since the JSON schema's `sliceType` maps naturally to DCB components). User can override to Aggregate approach, or use a Hybrid approach (independent entities as aggregates, interdependent entities as DCB slices sharing a `DcbEventLog`).

3. **Build shared event log** (DCB): Create a `DcbEventLog` for the plugin. Each slice declares its own `producedEvent` and `consumedEvent` types. Infer DCB tags from `idAttribute: true` fields → generate `@s.matches(DcbTag.string)` annotations on command and produced event fields.

4. **Generate StateChangeSlices**: For each `STATE_CHANGE` slice, place the file at `src/<chapter>/<SliceName>/StateChangeSlice/<SliceName>.res`. Open with `@@reventless.spec` — the PPX will auto-inject `let name`, `module Id`, `let moduleUrl`, and DCB tag annotations based on the `*Slice/` folder context:
   - Command from `commands[]` → `@schema type command` variant
   - Produced events from `events[]` → `@schema type producedEvent` variant (DCB tag annotations auto-injected by PPX for `*Id` fields)
   - Consumed events inferred from dependencies → `@schema type consumedEvent` variant
   - Generate **skeleton** `state`, `initialState`, `evolve`, `decide` with TODO placeholders

5. **Generate StateViewSlices**: Place at `src/<chapter>/<SliceName>/StateViewSlice/<SliceName>.res`. Open with `@@reventless.spec` — the PPX auto-injects `open Reventless.Projection`, `let config = config()`, `let subIdConfig = None`:
   - State from `readmodels[].fields` → `@schema type state` record (with `@id` annotation on the identity field)
   - Consumed events from dependencies → `@schema type consumedEvent` variant
   - Generate **skeleton** `project` function with TODO placeholders

6. **Generate AutomationSlices**: Place at `src/<chapter>/<SliceName>/AutomationSlice/<SliceName>.res`. Open with `@@reventless.spec`:
   - Extract trigger event and target command from `dependencies`
   - Generate **skeleton** `todoItem` type, `collect`, `resolve`, `process`, `maxRetries`, `heartbeatInterval` with TODO placeholders

7. **Infer cross-context connections**: Elements with `context: "EXTERNAL"` or dependencies to other contexts:
   - Generate `-spec` package with ExtensionPoint definition
   - Generate Extension mapping skeleton at `src/ExtensionPoint/<Name>ExtensionPointMapping.res` (PPX auto-injects `open ReventlessInfra.ExtensionPointMapping`)

8. **Generate test skeletons** from `specifications[]`:
   - Each specification → Jest `test` (async) with Given (events to replay), When (command to send), Then (expected events or errors)

9. **Do NOT generate Plugin.res** — this file is auto-generated by the `generate-plugin` prebuild script by scanning the folder structure. The structural chapter folder hierarchy created in steps 4–7 is all that is needed.

**What PPX eliminates from code generation** (no longer needs to be written or generated):

| Boilerplate | PPX Handles It |
|-------------|----------------|
| `let name = "SliceName"` | `@@reventless.spec` derives from filename |
| `module Id` | `@@reventless.spec` auto-injects |
| `let moduleUrl` | Both `@@reventless.spec` and `@@reventless.behavior` auto-inject |
| `@s.matches(DcbTag.string)` on `*Id` fields | Auto-applied in all `*Slice/` folders |
| `open Reventless.Projection` + `let config = config(); let subIdConfig = None` | Auto-injected for `StateViewSlice/` files |
| `open ReventlessInfra.ExtensionPointMapping` | Auto-injected for `*ExtensionPointMapping*` files |
| `open Spec; module Spec = Spec` in Behavior files | `@@reventless.behavior` handles it |
| `Plugin.res` wiring | `generate-plugin` prebuild script |

**Gaps requiring manual completion**:

| Gap | What the Developer Must Write |
|-----|------------------------------|
| `state` type | Define the record fields that guard command acceptance |
| `initialState` | Set initial values for each state field |
| `evolve` function | Pattern match on consumed events to update the state |
| `decide` function | Pattern match on state + command → `Ok(producedEvents)` or `Error(error)` |
| `project` function | Pattern match on consumed events → `Set`, `Update`, `Delete`, `Ignore` actions |
| `@schema type error` | Define error variant types (partially inferrable from `SPEC_ERROR` in specifications) |
| `consumedEvent` partitioning | Which events each slice consumes and which fields it needs (payload-less vs. partial vs. full) |
| `collect`/`resolve`/`process` | Automation slice internals — which events trigger, which resolve, how to process |
| `translate` function | Translation rules for inbound/outbound slices |
| Extension mapping functions | `mapIncomingEvent` / `mapOutgoingEvent` implementations |
| Temporal chapters | Not inferable from JSON — add `type summary` + `initFromSummary`/`toSummary` manually for long-lived entities after import (see [chapters-in-event-modeling.md](chapters-in-event-modeling.md)) |

### 5.3 Round-Trip Fidelity

**Reventless → JSON → Reventless** (export then reimport):

Lossless elements:
- Command and event names
- Field names and basic types
- Slice/component names and grouping by context (plugin)
- Cross-component connections (which command produces which events)
- `idAttribute` → DCB tag on identity fields
- Structural chapters: subfolder grouping → `slice.context` dotted suffix → subfolder grouping

Lost in round-trip:
- Ephemeral state logic (evolve/decide) — must be re-implemented
- Projection mapping logic (project) — must be re-implemented
- Aggregate behavioral state (initialState/evolve) — must be re-implemented
- Produced/consumed event decoupling (which fields each slice actually needs) — must be re-partitioned
- Translation rules — must be re-implemented
- Error types (partially recoverable from specifications)
- Extension point mapping functions
- Plugin-level config (heartbeat interval)
- Complex field types (`option<T>`, variant types, abstract types)
- **Temporal chapters entirely** — no round-trip possible; must be re-added manually after reimport

Gained in round-trip:
- Given/When/Then specifications (if the visual tool added them)
- Actor definitions
- UI screen references

---

## 6. Recommended Usage

### 6.1 When to Use Event Modeling JSON

- **Starting from visual design**: Team designs the system in Miro → exports JSON → imports to Reventless as a skeleton → completes the logic manually
- **Communicating with non-Reventless teams**: Export JSON for teams using other frameworks that also support the schema
- **Visualizing an existing system**: Export from Reventless → import to Miro for visual review and stakeholder communication

### 6.2 When NOT to Use Event Modeling JSON

- **As the source of truth**: The JSON cannot represent decision logic, projections, or DCB concepts — the ReScript code is the source of truth
- **For CI/CD validation**: The JSON is too lossy for automated drift detection — use the Reventless Markdown format instead (see `reventless-markdown-spec-conversion.md`)
- **For complete code generation**: The JSON produces skeletons with TODO placeholders, not production-ready code

### 6.3 Recommended Workflow

```
Design in Miro ──export──► Event Modeling JSON
                                    │
                              import (skeleton)
                                    │
                                    ▼
                           ReScript code (with TODOs)
                                    │
                           manual completion
                                    │
                                    ▼
                           ReScript code (complete)
                                    │
                              extract (full)
                                    │
                                    ▼
                          Reventless Markdown (documentation)
```

The JSON serves as the **initial bootstrap** from visual design. The Reventless Markdown format (see `reventless-markdown-spec-conversion.md`) serves as the **ongoing documentation** that can fully represent the system.

---

## 7. Open Questions

1. **Custom schema extensions?** Could Reventless-specific concepts be added to the JSON schema via custom fields (e.g., `x-reventless-state`, `x-reventless-dcbTags`, `x-reventless-consumedEvents`)? This would make the JSON lossless for Reventless but break compatibility with other Event Modeling tools.

2. **Specification-to-test pipeline**: The JSON's Given/When/Then specs map naturally to Jest test cases. Should Reventless provide a generator that reads specifications from JSON and produces `.res` test files?

3. **Event Modeling JSON as canonical source?** If teams design in the Miro toolkit first, the JSON export could be the starting point for generating ReScript. However, the JSON lacks critical Reventless concepts (ephemeral state, projections, DCB tags, produced/consumed event partitioning), so it can only serve as a structural skeleton — not a complete spec.

4. **Syncing specifications**: When the code evolves beyond the initial JSON import, should specifications be synced back to the JSON? Or should test scenarios live exclusively in `.res` test files after the initial bootstrap?

5. **Hybrid approach detection**: Could the import step automatically suggest which entities should be aggregates vs. DCB slices based on cross-entity dependency analysis in the JSON? Entities with no shared events across slices are candidates for the aggregate approach; entities with overlapping events suggest DCB.

6. **Encoding temporal chapters in JSON extensions?** If teams want to design temporal chapter boundaries in the Miro toolkit, the schema would need a custom extension (e.g., `x-reventless-chapterBoundary: true` on specific event elements). This would allow the import step to generate the `type summary` + `initFromSummary`/`toSummary` skeletons automatically. However, this breaks schema compatibility with any other consumer of Dilger's format.

7. **Structural chapter detection from `slice.aggregates[]`**: When importing, could the `aggregates[]` string array on each slice be used to suggest entity-group subfolder names (structural chapters), rather than relying entirely on `slice.context`? Entities that appear across many slices at similar timeline positions are natural structural chapter candidates.

---

## Related Analyses

- [chapters-in-event-modeling.md](chapters-in-event-modeling.md) — Full analysis of both structural chapters (folder organization, swimlanes, PPX conventions — already implemented) and temporal chapters ("Closing the Books" — optional, not in JSON schema). The two chapter types have very different implications for the import/export workflow described here.
