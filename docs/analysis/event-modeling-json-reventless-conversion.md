# Reventless ↔ Event Modeling JSON Schema: Conversion Analysis

## 1. Overview

Martin Dilger (Nebulit / eventmodelers.de) created a JSON schema for Event Modeling, originally designed for his Miro-based Event Modeling Toolkit. The schema is published at [github.com/dilgerma/event-modeling-spec](https://github.com/dilgerma/event-modeling-spec) (`eventmodeling.schema.json`, JSON Schema Draft 07, MIT license). A CLI code generator ([embuilder-node](https://github.com/dilgerma/embuilder-node)) consumes this format.

### 1.1 Adoption and Standardization Status

**Dilger's schema is not a standard.** It has very low adoption (13 GitHub stars, 2 forks) and is used almost exclusively within Nebulit's own Miro toolkit and code generator. No other project was found that imports, validates against, or generates this schema. Adam Dymitruk's eventmodeling.org does not reference or endorse any JSON schema — the site is purely conceptual.

The event modeling community has **no agreed-upon interchange format**. The landscape is fragmented:

| Project | Format | Notes |
|---------|--------|-------|
| **dilgerma/event-modeling-spec** | JSON Schema (Draft 07) | Nebulit's Miro toolkit. 13 stars. |
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
| `actors` | Actor[] | Users/external systems |
| `aggregates` | string[] | Aggregate names referenced by this slice |

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

**Field:**

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Field name |
| `type` | enum | `String`, `Boolean`, `Double`, `Decimal`, `Long`, `Custom`, `Date`, `DateTime`, `UUID`, `Int` |
| `subfields` | Field[] | Nested/complex types (recursive) |
| `example` | string/object | Example value |
| `optional` | boolean | Whether the field is optional |
| `idAttribute` | boolean | Whether this is the identity field |
| `cardinality` | enum | `List` or `Single` |
| `generated` | boolean | Auto-generated field |

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

Each `SpecificationStep` has a `type` enum: `SPEC_EVENT`, `SPEC_COMMAND`, `SPEC_READMODEL`, `SPEC_ERROR`.

### 2.1 Key Design Characteristics

1. **Flat element model**: Commands, events, read models, screens, and automations all share the same `Element` type — differentiated only by the `type` enum.
2. **Slice-centric**: No top-level aggregate or bounded context definitions — those are string references on slices and elements.
3. **Graph-based connections**: Elements carry `dependencies[]` with `INBOUND`/`OUTBOUND` direction, forming an explicit connection graph.
4. **Specifications are first-class**: Given/When/Then scenarios are built into the schema at the slice level.
5. **Visual-tool oriented**: Includes `screens`, `screenImages`, `actors`, `index` (timeline ordering), `sketched` flags — designed for visual Event Modeling tools, not code generation.

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

---

## 3. Gap Analysis: What Each Side Cannot Express

### 3.1 Reventless Concepts Missing from Event Modeling JSON

The JSON schema was designed for visual Event Modeling (the methodology), not for framework-specific code generation. The following Reventless concepts have no representation:

| Reventless Concept | Description | Impact |
|-------------------|-------------|--------|
| **Decision model** (`decisionModel`, `initialDecisionModel`) | Ephemeral state rebuilt per command to guard acceptance | Cannot generate the state type or its initial value |
| **Reduce function** (`reduce`) | Folds events into the decision model | No way to express which events affect which decision model fields |
| **Decide function** (`decide`) | Pattern-matches on decision model + command → events or errors | No way to express the acceptance/rejection logic |
| **Behavioral state** (`state`, `init`, `apply`) | Aggregate state machine for the aggregate approach | No concept of state reconstruction from events |
| **Create vs. Execute** distinction | Different handlers for new vs. existing aggregates | `createsAggregate` exists but only as a boolean flag, not separate logic paths |
| **Projection logic** (`project`, `map`) | How events map to read model state changes (Set, Update, Delete, etc.) | Read models exist as elements but their projection rules are opaque |
| **DCB tags** (`@s.matches(DcbTag.string)`) | Content-based event filtering for Dynamic Consistency Boundaries | No equivalent — `idAttribute` partially overlaps but serves a different purpose |
| **Shared event log** (DcbEventLog) | Single event log shared across all slices in a plugin | Events belong to individual slices, not a shared log |
| **Error types** as structured variants | Typed error variants with payloads (e.g., `ProductNotFound`) | Only `SPEC_ERROR` in specifications — not type definitions |
| **Extension point protocol** | Formal EP with `command`, `event`, `directive` types | Dependencies link elements but have no EP/extension contract semantics |
| **Extension mapping** (`mapIncomingEvent`, `mapOutgoingEvent`) | How EP events translate to internal commands and vice versa | No mapping function concept |
| **Inbound translation** (`externalInput`, `translate`) | Anti-corruption layer for external input validation | No equivalent — `AUTOMATION` has no `translate` structure |
| **Outbound translation** (`outboundItem`, `translate`) | Async external service calls with retry | No equivalent — `AUTOMATION` has no collect/translate/resolve |
| **Automation slice internals** (`collect`, `resolve`, `process`, `todoItem`) | TODO-list pattern with pending work tracking | `AUTOMATION` slice type exists but is structurally empty |
| **Plugin as deployment unit** | Plugin bundles aggregates/slices, EPs, extensions | No plugin concept — `context` is a flat string |
| **Platform composition** | Assembles plugins with version | No top-level composition |
| **Heartbeat interval** | Per-plugin polling configuration | No infrastructure config |
| **sury/schema annotations** | `@schema`, `@s.matches` for serialization | No serialization concept |
| **GraphQL resolver config** | `resolverConfig.fields` for API generation | `apiEndpoint` exists but is a flat string, not a structured config |

### 3.2 Event Modeling JSON Concepts Missing from Reventless

The JSON schema captures visual modeling and specification concepts that Reventless does not:

| JSON Schema Concept | Description | Impact |
|--------------------|-------------|--------|
| **Given/When/Then specifications** | Structured test scenarios with example data per slice | Reventless tests exist as separate `.res` files — no structured spec format in the framework |
| **UI screens** (`screens[]`, `screenImages[]`) | Wireframe references linked to slices | Reventless is backend-only — no UI modeling |
| **Actors** (`actors[]` with `name`, `authRequired`) | Who triggers which commands | Reventless has no actor/persona concept |
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
| **Bounded context** | Plugin name | `slice.context` / `element.modelContext` | 1:1 mapping possible but plugin carries more semantics (deployment unit, heartbeat, etc.) |
| **Command → Event flow** | Decide/Create/Execute functions | `dependencies[]` with INBOUND/OUTBOUND | JSON captures the connection but not the logic |
| **Event → ReadModel flow** | Projection Mapping / StateViewSlice project | `dependencies[]` from event to readmodel | JSON captures the connection but not the projection rules |
| **Cross-boundary communication** | ExtensionPoint + Extension with typed mapping | Elements with `context: "EXTERNAL"` + dependencies | JSON has no formal protocol — just "external" markers |
| **Field types** | Rich ReScript type system (`string`, `float`, `option<T>`, `array<T>`, records) | Limited enum (`String`, `Int`, `Double`, `UUID`, `Custom`) + `subfields` | `option`, variant types, and abstract types have no direct mapping |
| **Automation** | AutomationSlice with collect/resolve/process/todoItem | `sliceType: "AUTOMATION"` with `processors[]` | JSON has the category but none of the internal structure |

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
   - Mark commands that create new aggregates with `createsAggregate: true` (inferred from `create` handler or `initialDecisionModel`)

3. **Map field types**: `string` → `String`, `int` → `Int`, `float` → `Double`, `bool` → `Boolean`, `option<T>` → field with `optional: true`. Mark DCB-tagged fields with `idAttribute: true`.

4. **Build dependency graph**: For each command → event relationship (from Decide/Create/Execute), add `OUTBOUND` dependency on the command and `INBOUND` on the event. For projection mappings, add dependencies from events to read models.

5. **Map cross-plugin connections**: Extension point mappings → dependencies between elements with `context: "EXTERNAL"`.

6. **Set context**: Plugin name → `context` on all slices in that plugin.

7. **Generate specifications** from test files if available (parse Jest test structure for Given/When/Then patterns), or leave `specifications: []`.

**Information lost in export**:

| Lost Concept | Workaround |
|-------------|------------|
| Decision model + reduce/decide logic | None — not representable. Could add as `description` prose. |
| Projection mapping rules | None — read models appear but without mapping logic. |
| Behavioral state (init/apply) | None — aggregate state machine is opaque. |
| Error types as structured variants | Partially recoverable from `SPEC_ERROR` in specifications. |
| DCB tags (beyond `idAttribute`) | Could use `tags[]` on fields for non-ID tagged fields, but this is non-standard. |
| Translation rules (inbound/outbound) | None — automation slices appear but without internal structure. |
| EP/Extension protocol and mappings | External dependencies capture connections but not the mapping functions. |

### 5.2 Event Modeling JSON → Reventless (import)

**Input**: Event Modeling JSON file (exported from Miro toolkit or embuilder)
**Output**: ReScript source files (`.res`)

**Workflow**:

1. **Group slices by context**: The `context` field on each slice maps to a Reventless plugin. Create one plugin package per unique context value.

2. **Determine approach**: Default to DCB (since the JSON schema's `sliceType` maps naturally to DCB components). User can override to Aggregate approach.

3. **Build shared event log** (DCB): Collect all unique events across all slices in the same context. Deduplicate by `title`. Infer DCB tags from `idAttribute: true` fields → generate `@s.matches(DcbTag.string)` annotations.

4. **Generate StateChangeSlices**: For each `STATE_CHANGE` slice:
   - Command from `commands[]` → `@schema type command` variant
   - Events from `events[]` → already in the shared event log
   - Generate **skeleton** `decisionModel`, `initialDecisionModel`, `reduce`, `decide` with TODO placeholders

5. **Generate StateViewSlices**: For each `STATE_VIEW` slice:
   - State from `readmodels[].fields` → `@schema type state` record
   - Generate **skeleton** `project` function with TODO placeholders

6. **Generate AutomationSlices**: For each `AUTOMATION` slice:
   - Extract trigger event and target command from `dependencies`
   - Generate **skeleton** `collect`, `resolve`, `process` with TODO placeholders

7. **Infer cross-context connections**: Elements with `context: "EXTERNAL"` or dependencies to other contexts:
   - Generate `-spec` package with ExtensionPoint definition
   - Generate Extension mapping skeleton

8. **Generate test skeletons** from `specifications[]`:
   - Each specification → Jest `testPromise` with Given (events to replay), When (command to send), Then (expected events or errors)

9. **Generate Plugin.res wiring** and **Main.res platform assembly**.

**Gaps requiring manual completion**:

| Gap | What the Developer Must Write |
|-----|------------------------------|
| `decisionModel` type | Define the record fields that guard command acceptance |
| `initialDecisionModel` | Set initial values for each decision model field |
| `reduce` function | Pattern match on events to update the decision model |
| `decide` function | Pattern match on decision model + command → `Ok(events)` or `Error(error)` |
| `project` function | Pattern match on events → `Set`, `Update`, `Delete`, `Ignore` actions |
| `@schema type error` | Define error variant types (partially inferrable from `SPEC_ERROR` in specifications) |
| `collect`/`resolve`/`process` | Automation slice internals — which events trigger, which resolve, how to process |
| `translate` function | Translation rules for inbound/outbound slices |
| Extension mapping functions | `mapIncomingEvent` / `mapOutgoingEvent` implementations |

### 5.3 Round-Trip Fidelity

**Reventless → JSON → Reventless** (export then reimport):

Lossless elements:
- Command and event names
- Field names and basic types
- Slice/component names and grouping by context
- Cross-component connections (which command produces which events)
- `idAttribute` → DCB tag on identity fields

Lost in round-trip:
- Decision model logic (reduce/decide) — must be re-implemented
- Projection mapping logic (project) — must be re-implemented
- Behavioral state (init/apply) — must be re-implemented
- Translation rules — must be re-implemented
- Error types (partially recoverable from specifications)
- Extension point mapping functions
- Plugin-level config (heartbeat interval)
- Complex field types (`option<T>`, variant types, abstract types)

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

1. **Custom schema extensions?** Could Reventless-specific concepts be added to the JSON schema via custom fields (e.g., `x-reventless-decisionModel`, `x-reventless-dcbTags`)? This would make the JSON lossless for Reventless but break compatibility with other Event Modeling tools.

2. **Specification-to-test pipeline**: The JSON's Given/When/Then specs map naturally to Jest test cases. Should Reventless provide a generator that reads specifications from JSON and produces `.res` test files?

3. **Event Modeling JSON as canonical source?** If teams design in the Miro toolkit first, the JSON export could be the starting point for generating ReScript. However, the JSON lacks critical Reventless concepts (decision models, projections, DCB tags), so it can only serve as a structural skeleton — not a complete spec.

4. **Syncing specifications**: When the code evolves beyond the initial JSON import, should specifications be synced back to the JSON? Or should test scenarios live exclusively in `.res` test files after the initial bootstrap?
