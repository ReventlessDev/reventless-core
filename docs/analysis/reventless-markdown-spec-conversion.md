# Bi-Directional Conversion: ReScript Specs ↔ Markdown Description

## 1. Motivation

A human-readable markdown description of a platform and its plugins would serve multiple purposes:

- **Documentation**: Always-up-to-date, readable spec of the entire system
- **AI-assisted development**: An LLM can read the markdown to understand the system, then generate ReScript specs from it (or vice versa)
- **Domain expert collaboration**: Non-developers can review and propose changes to the system design in markdown before code is written
- **Diffing & review**: Markdown diffs are easier to review than ReScript code changes for domain-level changes
- **Bootstrapping**: Describe a new plugin in markdown, generate the ReScript skeleton

---

## 2. What Must Be Captured

Every element that defines the system's behavior must appear in the markdown. The following is an exhaustive inventory of all spec parameters, grouped by component type.

### 2.1 Aggregate (aggregate approach only)

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | string | Aggregate name (e.g., "Product") |
| `Id` module | Id.String / Id.StringPure | Identity type |
| `command` | variant type | All command variants with payloads |
| `event` | variant type | All event variants with payloads |
| `error` | variant type | Business rule violation variants |

### 2.2 Behavior (aggregate approach only)

| Parameter | Type | Description |
|-----------|------|-------------|
| `Spec` | module ref | Which aggregate this behavior implements |
| `state` | record type | Internal aggregate state (rebuilt from events) |
| `resolverConfig.fields` | array of strings | GraphQL resolver fields |
| `init` | `event → state` | Build initial state from first event |
| `apply` | `(state, event) → state` | Fold event into current state |
| `create` | `(command, context, errorHandler) → events` | Handle commands on new aggregates |
| `execute` | `(state, command, context, errorHandler) → events` | Handle commands on existing aggregates |

### 2.3 DcbEventLog (DCB approach only)

| Parameter | Type | Description |
|-----------|------|-------------|
| `event` | variant type | Union of ALL events in the shared log, with `@s.matches(DcbTag.string)` on entity ID fields |

### 2.4 StateChangeSlice (DCB approach only)

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | string | Slice name |
| `DcbEventLogSpec` | module ref | Which shared event log |
| `command` | variant type | Commands this slice handles (with DCB tags on entity IDs) |
| `error` | variant type | Business rule violations |
| `decisionModel` | record type | Ephemeral read model rebuilt per command |
| `initialDecisionModel` | value | Starting state of decision model |
| `reduce` | `(decisionModel, event) → decisionModel` | Fold events into decision model |
| `decide` | `(decisionModel, command) → result` | Decision logic producing events or errors |

### 2.5 StateViewSlice (DCB approach only)

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | string | View name |
| `DcbEventLogSpec` | module ref | Which shared event log |
| `event` | variant type | Subset of DCB events this view listens to |
| `state` | record type | Projected read model state |
| `project` | `(option<state>, event) → actions` | Event-to-projection-action mapping |

### 2.6 AutomationSlice (DCB approach only)

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | string | Slice name |
| `DcbEventLogSpec` | module ref | Which shared event log |
| `todoItem` | record type | Pending work item data |
| `command` | variant type | Commands produced by the processor |
| `collect` | `event → array<(id, todoItem)>` | Extract pending items from events |
| `resolve` | `event → option<id>` | Mark TODO as done when completion event arrives |
| `process` | `(id, todoItem) → option<(id, command)>` | Generate command for pending item |
| `maxRetries` | int | Maximum retry count |
| `heartbeatInterval` | int | Polling interval in seconds |

### 2.7 OutboundTranslationSlice (DCB approach only)

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | string | Slice name |
| `DcbEventLogSpec` | module ref | Which shared event log |
| `outboundItem` | record type | Data to send to external service |
| `inboundCommand` | variant type | Optional command from external response |
| `collect` | `event → array<(id, outboundItem)>` | Extract items from events |
| `translate` | `(id, item) → promise<result>` | Call external service |
| `maxRetries` | int | Maximum retry count |
| `heartbeatInterval` | int | Polling interval in seconds |

### 2.8 InboundTranslationSlice (DCB approach only)

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | string | Slice name |
| `DcbEventLogSpec` | module ref | Which shared event log |
| `externalInput` | record type | External input type |
| `command` | variant type | Translated command |
| `translate` | `input → result<(id, command), string>` | Anti-corruption logic |

### 2.9 ReadModel (aggregate approach only)

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | string | Read model name |
| `Id` module | Id.String / Id.StringPure | Identity type |
| `state` | record type | Projected state |
| `config` | ReadModel.config | Infrastructure config (indexes, resolvers) |
| `subIdConfig` | option | Composite-key config |

### 2.10 Projection Mapping (aggregate approach only)

| Parameter | Type | Description |
|-----------|------|-------------|
| Source | Aggregate module | Which aggregate's events to project |
| Target | ReadModel module | Which read model to project into |
| `map` | `(event message) → action` | Event-to-action mapping |

### 2.11 ExtensionPoint (both approaches)

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | string | Stable public API name (e.g., "Catalog.Products") |
| `command` | variant type | Commands extensions can send (often `unit`) |
| `event` | variant type | Events emitted to subscribers |
| `directive` | variant type | Internal routing directives (often `unit`) |

### 2.12 ExtensionPoint Mapping (both approaches)

| Parameter | Type | Description |
|-----------|------|-------------|
| `ExtensionPoint` | module ref | Which extension point |
| `Aggregate` | module ref | Which internal aggregate/event log |
| `mapIncomingCommand` | mapping fn | EP commands → aggregate commands |
| `mapOutgoingEvent` | option of mapping fn | Aggregate events → EP events |

### 2.13 Extension Mapping (both approaches)

| Parameter | Type | Description |
|-----------|------|-------------|
| `Source` (ExtensionPoint) | module ref | Which external EP to subscribe to |
| `Target` (Aggregate) | module ref | Which internal aggregate/slice to command |
| `mapIncomingEvent` | mapping fn | EP events → aggregate commands |
| `mapOutgoingEvent` | option of mapping fn | Aggregate events → EP commands |

### 2.14 EventMapping (aggregate approach only)

| Parameter | Type | Description |
|-----------|------|-------------|
| `Source` | Aggregate module | Source of events |
| `Target` | Aggregate module | Target for commands |
| `map` | `(id, event, queryEngine) → actions` | Event-to-command mapping |

### 2.15 SideEffect (aggregate approach only)

| Parameter | Type | Description |
|-----------|------|-------------|
| `Source` | Aggregate module | Event source |
| `execute` | `(id, meta, event, queryEngine) → promise<unit>` | Async handler |

### 2.16 Task (aggregate approach only)

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | string | Task name |
| `buckets` | array of bucket configs | S3 buckets with mode and callbacks |

### 2.17 Plugin Composition

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | string | Plugin name |
| `heartbeatInterval` | int | Heartbeat in seconds |
| `aggregates` | array | List of aggregate components (aggregate approach) |
| `readModels` | array | List of read model components (aggregate approach) |
| `dcbSpec` | module | DCB event log + all slices (DCB approach) |
| `extensionPoints` | array | Extension points this plugin exposes |
| `extensions` | array | Extensions subscribing to other plugins' EPs |
| `tasks` | array | Task components |

### 2.18 Platform

| Parameter | Type | Description |
|-----------|------|-------------|
| `version` | string | Platform version |
| `plugins` | array | All plugins in the platform |

---

## 3. Proposed Markdown File Structure

### Option A: 1 file per plugin + 1 platform file (recommended)

```
specs/
├── platform.md                    # Platform overview + plugin list
├── catalog.md                     # Catalog plugin (all components)
├── catalog-extension-points.md    # Catalog's public API (extension points)
├── ordering.md                    # Ordering plugin (all components)
└── ordering-extension-points.md   # Ordering's public API (extension points)
```

**Rationale**: Extension point specs are the **public API contract** between plugins. They live in separate `-spec` packages in the code and are consumed by other plugins. Keeping them in separate markdown files mirrors this separation:

- A plugin author can read another plugin's `-extension-points.md` without needing to understand its internals
- The main plugin file contains all internal components (aggregates/slices, read models, behaviors, mappings)
- The platform file is a lightweight composition root listing which plugins exist and how they connect

### Why not other splits?

- **1 file per component**: Too granular — a plugin with 10 slices would produce 10+ tiny files. The relationships between components (e.g., which events a slice produces, which view consumes them) are easier to understand when they're in one document.
- **1 file per entity/domain concept**: Tempting (e.g., `product.md` covering Product aggregate + ProductsView + AddProduct slice), but breaks down for cross-cutting components like extension points and automation slices that span multiple entities.
- **Separate files for types vs. logic**: Splits the spec unnaturally — understanding a StateChangeSlice requires seeing its command type, decision model, and decide function together.

---

## 4. Proposed Markdown Format

### 4.1 Platform File (`platform.md`)

**Template:**

````
# Platform: {PlatformName}

- **Version**: {version}
- **Approach**: {DCB | Aggregate | Mixed}

## Plugins

| Plugin | Approach | Extension Points | Extensions |
|--------|----------|-----------------|------------|
| {PluginName} | {DCB|Aggregate} | {EP1, EP2, ...} | {EP1, EP2, ...} |

## Cross-Plugin Connections

- {PluginA} **subscribes to** {EP} → routes to {target slice/aggregate}
````

**Rendered example:**

#### Platform: OnlineShop

- **Version**: from package.json
- **Approach**: Mixed

##### Plugins

| Plugin | Approach | Extension Points | Extensions |
|--------|----------|-----------------|------------|
| Catalog | DCB | Catalog.Products | Ordering.Orders |
| Ordering | DCB | Ordering.Orders | Catalog.Products |

##### Cross-Plugin Connections

- Catalog **subscribes to** Ordering.Orders → routes to RecordProductDemand
- Ordering **subscribes to** Catalog.Products → routes to SyncCatalogProduct

---

### 4.2 Extension Point File (`catalog-extension-points.md`)

**Template:**

````
# Extension Points: {PluginName}

## {ExtensionPointName}

{Description}

### Events

| Event | Fields | Description |
|-------|--------|-------------|
| {EventName} | {field: type, ...} | {description} |

### Commands

| Command | Fields | Description |
|---------|--------|-------------|
| {CommandName} | {field: type, ...} | {description} |

### Directives

| Directive | Fields | Description |
|-----------|--------|-------------|
| {DirectiveName} | {field: type, ...} | {description} |
````

**Rendered example:**

#### Extension Points: Catalog

##### Catalog.Products

Stable public API for product availability and pricing.

**Events:**

| Event | Fields | Description |
|-------|--------|-------------|
| ProductBecameAvailable | productId: string, name: string, price: float | A new product is available |
| ProductPriceChanged | productId: string, price: float | Product price was updated |

**Commands:** _None (read-only extension point)_

**Directives:** _None_

---

### 4.3 Plugin File — DCB Approach (`catalog.md`)

**Template:**

````
# Plugin: {PluginName}

- **Approach**: DCB
- **Heartbeat Interval**: {seconds}s
- **Event Log**: {EventLogName}

## Event Log: {EventLogName}

{Description}

| Event | Fields | DCB Tags |
|-------|--------|----------|
| {EventName} | {field: type, ...} | {taggedField1, taggedField2} |

---

## State Change Slices

### {SliceName}

{Description}

**Command:**
| Variant | Fields | DCB Tags |
|---------|--------|----------|
| {VariantName} | {field: type, ...} | {taggedField} |

**Errors:** {Error1, Error2, ...}

**Decision Model:**
| Field | Type | Initial |
|-------|------|---------|
| {field} | {type} | {value} |

**Reduce:**
| Event | Effect |
|-------|--------|
| {EventName} | → {new decision model state} |
| _ | → unchanged |

**Decide:**
| Condition | Result |
|-----------|--------|
| {condition on decision model} | {Ok([events]) | Error(error)} |

---

## State View Slices

### {ViewName}

{Description}

**State:**
| Field | Type |
|-------|------|
| {field} | {type} |

**Projections:**
| Event | Action |
|-------|--------|
| {EventName} | {Set|Update|Create|Delete|Ignore}({id}, {state expression}) |

---

## Automation Slices

### {SliceName}

{Description}

**Todo Item:**
| Field | Type |
|-------|------|
| {field} | {type} |

**Command:**
| Variant | Fields | DCB Tags |
|---------|--------|----------|
| {VariantName} | {field: type, ...} | {taggedField} |

**Collect:**
| Event | Items |
|-------|-------|
| {EventName} | ({id}, {{fields}}) |

**Resolve:**
| Event | Resolution |
|-------|------------|
| {EventName} | resolved by {id field} |

**Process:** ({id}, {todoItem}) → ({id}, {Command})

**Config:** maxRetries: {n}, heartbeatInterval: {seconds}s

---

## Outbound Translation Slices

### {SliceName}

{Description}

**Outbound Item:**
| Field | Type |
|-------|------|
| {field} | {type} |

**Inbound Command:** {variant type or unit}

**Collect:**
| Event | Items |
|-------|-------|
| {EventName} | ({id}, {{fields}}) |

**Translate:** {description of external service call and return}

**Config:** maxRetries: {n}, heartbeatInterval: {seconds}s

---

## Inbound Translation Slices

### {SliceName}

{Description}

**External Input:**
| Field | Type |
|-------|------|
| {field} | {type} |

**Command:**
| Variant | Fields | DCB Tags |
|---------|--------|----------|
| {VariantName} | {field: type, ...} | {taggedField} |

**Translation Rules:**
| Condition | Result |
|-----------|--------|
| {validation condition} | {Error("message") | Ok(id, Command({fields}))} |

---

## Extension Point Mappings

### {SourceEventLog} → {ExtensionPointName}

| Internal Event | External Event |
|---------------|----------------|
| {EventName}({fields}) | {EPEventName}({fields}) |
| _ | (not published) |

---

## Extensions

### Subscribes to: {ExtensionPointName} → {TargetSlice}

| External Event | Internal Command |
|---------------|------------------|
| {EPEventName}({fields}) | {CommandVariant}({fields}) |
````

**Rendered example:**

#### Plugin: Catalog

- **Approach**: DCB
- **Heartbeat Interval**: 60s
- **Event Log**: CatalogEventLog

##### Event Log: CatalogEventLog

All events in the Catalog plugin's shared event log.

| Event | Fields | DCB Tags |
|-------|--------|----------|
| ProductAdded | productId: string, name: string, description: string, price: float | productId |
| ProductNameChanged | productId: string, name: string | productId |
| ProductDescriptionChanged | productId: string, description: string | productId |
| ProductPriceChanged | productId: string, price: float | productId |
| CategoryAdded | categoryId: string, name: string | categoryId |
| CategoryRenamed | categoryId: string, name: string | categoryId |
| CategoryArchived | categoryId: string | categoryId |
| ProductDemandRecorded | productId: string, orderId: string | productId |
| ProductDemandRevoked | productId: string, orderId: string | productId |

##### State Change Slices

**AddProduct** — Handles product creation; rejects duplicates via DCB optimistic concurrency.

Command:

| Variant | Fields | DCB Tags |
|---------|--------|----------|
| AddProduct | productId: string, name: string, description: string, price: float | productId |

Errors: `ProductAlreadyExists`

Decision Model:

| Field | Type | Initial |
|-------|------|---------|
| exists | bool | false |

Reduce:

| Event | Effect |
|-------|--------|
| ProductAdded | → {exists: true} |
| _ | → unchanged |

Decide:

| Condition | Result |
|-----------|--------|
| exists = true | Error(ProductAlreadyExists) |
| exists = false | Ok([ProductAdded({...command fields})]) |

**ChangeProductName** — Handles product name updates.

Command:

| Variant | Fields | DCB Tags |
|---------|--------|----------|
| ChangeProductName | productId: string, name: string | productId |

Errors: `ProductNotFound`

Decision Model:

| Field | Type | Initial |
|-------|------|---------|
| exists | bool | false |
| currentName | `option<string>` | None |

Reduce:

| Event | Effect |
|-------|--------|
| ProductAdded | → {exists: true, currentName: Some(name)} |
| ProductNameChanged | → {..., currentName: Some(name)} |
| _ | → unchanged |

Decide:

| Condition | Result |
|-----------|--------|
| exists = false | Error(ProductNotFound) |
| currentName = Some(name) where name = command.name | Ok([]) (no-op) |
| otherwise | Ok([ProductNameChanged({productId, name})]) |

_...more StateChangeSlices follow the same pattern..._

##### State View Slices

**ProductsView** — Projects product events into a queryable product listing.

State:

| Field | Type |
|-------|------|
| productId | string |
| name | string |
| description | string |
| price | float |

Projections:

| Event | Action |
|-------|--------|
| ProductAdded | Set(productId, {productId, name, description, price}) |
| ProductNameChanged | Update(productId, state → {...state, name}) |
| ProductDescriptionChanged | Update(productId, state → {...state, description}) |
| ProductPriceChanged | Update(productId, state → {...state, price}) |
| _ | Ignore |

##### Inbound Translation Slices

**ImportProduct** — Receives external supplier JSON, validates and translates to AddProduct commands.

External Input:

| Field | Type |
|-------|------|
| sku | string |
| title | string |
| desc | string |
| unitPrice | int |
| currency | string |

Command:

| Variant | Fields | DCB Tags |
|---------|--------|----------|
| AddProduct | productId: string, name: string, description: string, price: float | productId |

Translation Rules:

| Condition | Result |
|-----------|--------|
| currency ≠ "USD" | Error("Unsupported currency") |
| unitPrice ≤ 0 | Error("Price must be positive") |
| sku = "" | Error("SKU is required") |
| otherwise | Ok(sku, AddProduct({productId: sku, name: title, desc: desc, price: unitPrice / 100.0})) |

##### Extension Point Mappings

**CatalogEventLog → Catalog.Products**

| Internal Event | External Event |
|---------------|----------------|
| ProductAdded({productId, name, price}) | ProductBecameAvailable({productId, name, price}) |
| ProductPriceChanged({productId, price}) | ProductPriceChanged({productId, price}) |
| _ | (not published) |

##### Extensions

**Subscribes to: Ordering.Orders → RecordProductDemand**

| External Event | Internal Command |
|---------------|------------------|
| ItemOrdered({productId, orderId}) | RecordDemand({productId, orderId}) |
| ItemOrderCancelled({productId, orderId}) | RevokeDemand({productId, orderId}) |

---

### 4.4 Plugin File — Aggregate Approach (`catalog.md`)

**Template:**

````
# Plugin: {PluginName}

- **Approach**: Aggregate
- **Heartbeat Interval**: {seconds}s

## Aggregates

### {AggregateName}

**Commands:**
| Variant | Fields |
|---------|--------|
| {VariantName} | {field: type, ...} |

**Events:**
| Variant | Fields |
|---------|--------|
| {VariantName} | {field: type, ...} |

**Errors:** {Error1, Error2, ...}

**Behavior State:**
| Field | Type |
|-------|------|
| {field} | {type} |

**Init (first event → state):**
| Event | State |
|-------|-------|
| {EventName} | {{field values}} |

**Apply (state + event → state):**
| Event | Effect |
|-------|--------|
| {EventName} | → {new state expression} |

**Create (new aggregate):**
| Command | Events |
|---------|--------|
| {CommandName} | [{EventName}({fields})] |

**Execute (existing aggregate):**
| Command | Condition | Events |
|---------|-----------|--------|
| {CommandName} | {condition} | [{EventName}({fields})] or Error({error}) |

---

## Read Models

### {ReadModelName}

**State:**
| Field | Type |
|-------|------|
| {field} | {type} |

**Projection from {AggregateName}:**
| Event | Action |
|-------|--------|
| {EventName} | {Set|Update|Create|Delete|Ignore}({id}, {state expression}) |

---

## Event Mappings

### {SourceAggregate} → {TargetAggregate}

| Source Event | Target Command |
|-------------|----------------|
| {EventName}({fields}) | {CommandName}({fields}) |

---

## Side Effects

### {SideEffectName}

- **Source**: {AggregateName} aggregate
- **Trigger**: {EventName} event
- **Action**: {description of side effect}

---

## Tasks

### {TaskName}

- **Bucket**: {bucket-name}
- **Mode**: {Read | Write | ReadWrite}
- **Trigger**: {event description}
- **Action**: {description}

---

## Extension Point Mappings

### {AggregateName} → {ExtensionPointName}

| Internal Event | External Event |
|---------------|----------------|
| {EventName}({fields}) | {EPEventName}({fields}) |

---

## Extensions

### Subscribes to: {ExtensionPointName} → {TargetAggregate}

| External Event | Internal Command |
|---------------|------------------|
| {EPEventName}({fields}) | {CommandVariant}({fields}) |
````

**Rendered example:**

#### Plugin: Catalog

- **Approach**: Aggregate
- **Heartbeat Interval**: 60s

##### Aggregates

**Product**

Commands:

| Variant | Fields |
|---------|--------|
| Add | name: string, description: string, price: float |
| UpdateName | name: string |
| UpdateDescription | description: string |
| UpdatePrice | price: float |

Events:

| Variant | Fields |
|---------|--------|
| Added | name: string, description: string, price: float |
| NameUpdated | name: string |
| DescriptionUpdated | description: string |
| PriceUpdated | price: float |

Errors: `ProductAlreadyExists`, `ProductNotFound`

Behavior State:

| Field | Type |
|-------|------|
| name | string |
| description | string |
| price | float |

Init (first event → state):

| Event | State |
|-------|-------|
| Added | {name, description, price} |

Apply (state + event → state):

| Event | Effect |
|-------|--------|
| Added | → {name, description, price} |
| NameUpdated | → {...state, name} |
| DescriptionUpdated | → {...state, description} |
| PriceUpdated | → {...state, price} |

Create (new aggregate):

| Command | Events |
|---------|--------|
| Add | [Added({name, description, price})] |
| UpdateName / UpdateDescription / UpdatePrice | Error(ProductNotFound) |

Execute (existing aggregate):

| Command | Condition | Events |
|---------|-----------|--------|
| Add | always | Error(ProductAlreadyExists) |
| UpdateName | name unchanged | [] (no-op) |
| UpdateName | name changed | [NameUpdated({name})] |
| UpdateDescription | unchanged | [] |
| UpdateDescription | changed | [DescriptionUpdated({description})] |
| UpdatePrice | unchanged | [] |
| UpdatePrice | changed | [PriceUpdated({price})] |

##### Read Models

**Products**

State:

| Field | Type |
|-------|------|
| productId | string |
| name | string |
| description | string |
| price | float |

Projection from Product:

| Event | Action |
|-------|--------|
| Added | Set(id, {productId: id, name, description, price}) |
| NameUpdated | Update(id, state → {...state, name}) |
| DescriptionUpdated | Update(id, state → {...state, description}) |
| PriceUpdated | Update(id, state → {...state, price}) |

##### Event Mappings

_(internal aggregate-to-aggregate routing)_

##### Side Effects

**Order_EmailNotification**

- **Source**: Order aggregate
- **Trigger**: OrderPlaced event
- **Action**: Send confirmation email

##### Tasks

**ImportProducts**

- **Bucket**: product-imports
- **Mode**: Read
- **Trigger**: ObjectCreated events
- **Action**: Publish Add commands to Product aggregate

---

## 5. Conversion Workflows

### 5.1 ReScript → Markdown (extraction)

**Input**: ReScript source files (`.res`)
**Output**: Markdown spec files

**Workflow**:

1. **Discover plugins**: Scan `examples/*/src/*Plugin.res` or `examples/*/src/Plugin/*Plugin.res` for `Platform.Plugin.make(~name=...)` calls. Extract plugin name, approach (presence of `~dcbSpec` vs `~aggregates`), heartbeat interval, and lists of components.

2. **Extract event log** (DCB): Find the `DcbEventLog` module. Parse the `@schema type event` variant to extract all event names, fields, and DCB tag annotations (`@s.matches(DcbTag.string)`).

3. **Extract aggregates** (Aggregate): Find `Aggregate.Spec` modules. Parse `command`, `event`, `error` variant types. Then find the corresponding `Behavior` module and parse `state`, `init`, `apply`, `create`, `execute`.

4. **Extract slices** (DCB): For each `StateChangeSlice`, parse `name`, `command`, `error`, `decisionModel`, `initialDecisionModel`, `reduce`, `decide`. For `StateViewSlice`, parse `name`, `state`, `project`. For automation/translation slices, parse their respective fields.

5. **Extract read models** (Aggregate): Parse `state` type and find `Projection.Mapping.Make` calls to extract the mapping logic.

6. **Extract extension points**: Find `-spec` packages, parse `name`, `command`, `event`, `directive`. Then find the mapping in the host plugin.

7. **Extract extensions**: Find `ExtensionMapping` modules, parse source EP and target aggregate/slice, and the mapping logic.

8. **Extract platform**: Find `Main.res`, parse `makePlatform` call to get plugin list and version.

9. **Render markdown**: Format each extracted structure using the templates in Section 4.

**Technical approach options**:

| Approach | Pros | Cons |
|----------|------|------|
| **AST parsing** (ReScript compiler internals) | Accurate types | Heavy dependency, version-coupled |
| **Regex/heuristic parsing** | Simple, no deps | Fragile for complex expressions |
| **ReScript compiler + `.cmt` files** | Typed AST available | Requires build step first |
| **LLM-assisted extraction** | Handles arbitrary code patterns | Non-deterministic, slower |
| **Hybrid: structured comments + regex** | Reliable, fast | Requires discipline in code |

**Recommended**: Start with **LLM-assisted extraction** for the initial implementation (Claude can read ReScript files and produce structured markdown). As the format stabilizes, build a **regex/heuristic parser** for CI automation. The structured table format in Section 4 is designed to be machine-parseable.

### 5.2 Markdown → ReScript (generation)

**Input**: Markdown spec files
**Output**: ReScript source files (`.res`)

**Workflow**:

1. **Parse platform file**: Extract plugin names, approach per plugin, cross-plugin connections.

2. **Parse extension point files**: Extract EP names, event/command variant types. Generate `-spec` package with `ExtensionPoint.res` for each.

3. **Parse plugin files**: For each plugin, based on approach:

   **DCB approach**:
   - Parse event log table → generate `EventLog.res` with `@schema type event` variant
   - Parse each state change slice section → generate `SliceName.res` with `name`, `DcbEventLogSpec`, `command`, `error`, `decisionModel`, `initialDecisionModel`, `reduce`, `decide`
   - Parse each state view slice section → generate `ViewName.res` with `name`, `DcbEventLogSpec`, `event`, `state`, `project`
   - Parse automation/outbound/inbound slices → generate respective `.res` files
   - Parse extension point mapping table → generate mapping module
   - Parse extension table → generate extension mapping module
   - Generate `Plugin.res` wiring all components

   **Aggregate approach**:
   - Parse aggregate sections → generate `AggregateName.res` (spec) and `AggregateBehavior.res`
   - Parse read model sections → generate `ReadModelName.res` and `Projections.res`
   - Parse event mappings, side effects, tasks → generate respective files
   - Generate `Plugin.res` wiring

4. **Generate platform `Main.res`**: Import all plugins, call `makePlatform`.

**Challenges in markdown → code**:

| Challenge | Mitigation |
|-----------|------------|
| **Logic expressions** in decide/reduce/translate can't be fully captured in tables | Use a mini-DSL in the markdown (pattern matching notation) or accept that complex logic requires manual editing |
| **Type references** across components (e.g., `DcbEventLogSpec.event`) | Resolved by file structure conventions — the event log is always referenced by plugin name |
| **Import paths** depend on package structure | Use conventions: plugin name → package name mapping |
| **sury annotations** (`@schema`, `@s.matches`) | Generated automatically based on component type and DCB tag column |
| **Guard conditions** in behavior execute (e.g., `if name == state.name`) | Captured in "Condition" column of decision tables |

### 5.3 Round-Trip Fidelity

For reliable bi-directional conversion, the markdown format must be **lossless** for structural information (types, variant names, field names, component wiring) but can be **lossy** for implementation details (complex guard expressions, helper functions, service calls).

**Lossless elements** (round-trip perfectly):
- All type definitions (commands, events, errors, states, decision models)
- Field names and types
- DCB tag annotations
- Component names and wiring
- Projection actions (Set, Update, Create, Delete, Ignore)
- Simple decide/reduce/translate logic (pattern match on variant → produce variant)

**Lossy elements** (require manual review after generation):
- Complex guard conditions with state comparisons
- Async external service calls (in translate, execute side effects)
- QueryEngine usage in mappings
- Helper functions and shared utilities
- Error message formatting

---

## 6. Field Type Notation

### 6.1 Primitive and Container Types

| Notation | ReScript Type | Example |
|----------|---------------|---------|
| `string` | `string` | `name: string` |
| `int` | `int` | `unitPrice: int` |
| `float` | `float` | `price: float` |
| `bool` | `bool` | `exists: bool` |
| `option<T>` | `option<T>` | `currentName: option<string>` |
| `array<T>` | `array<T>` | `items: array<string>` |
| `{...}` | inline record | `{id: string, name: string}` |
| `TypeName` | reference | `CatalogEventLog.event` |

DCB tags are indicated in a separate "DCB Tags" column listing which fields are tagged (rather than inline annotations).

### 6.2 Nested Types

In practice, user-facing domain specs (commands, events, states) are almost entirely **flat records with primitive fields**. The nesting patterns that do occur are limited:

| Pattern | Markdown Notation | ReScript | Prevalence |
|---------|------------------|----------|------------|
| Array of primitives | `productIds: array<string>` | `productIds: array<string>` | Common |
| Optional primitive | `delay?: int` | `delay?: int` | Common |
| Inline nested record | `address: {street: string, city: string}` | `address: {street: string, city: string}` | Rare in domain specs |
| Array of records | `items: array<{productId: string, qty: int}>` | `items: array<{productId: string, qty: int}>` | Rare in domain specs |
| Non-schema internal type | `availableIds: Set.t<string>` | `availableIds: Set.t<string>` | Decision models only |

**Flat tables handle the common case.** When a field has `array<string>`, the type column simply reads `array<string>` — no extra structure needed. For the rare inline nested record, the type column uses the `{...}` notation inline:

| Field | Type |
|-------|------|
| orderId | string |
| productIds | `array<string>` |
| address | `{street: string, city: string}` |

If a nested record is large enough to be unreadable inline, extract it as a **named type** with its own table:

**Types:**

| Type | Fields |
|------|--------|
| Address | street: string, city: string, zip: string, country: string |

Then reference it in the parent:

| Field | Type |
|-------|------|
| address | Address |

This mirrors how ReScript handles it — inline records for small types, named types for larger ones.

**Decision model fields** may use non-serializable types like `Set.t<string>` for runtime efficiency. These appear only in the decision model table and are notated as-is — code generation would use the ReScript type directly.

### 6.3 Payload-less Variants

Some variant types have constructors without payloads (e.g., `Ship`, `Cancel`, `ProductNotFound`). In the markdown tables:

- **Commands/Events with no fields**: Leave the Fields column empty or write `—`
- **Errors**: List as comma-separated names: `Errors: ProductAlreadyExists, ProductNotFound`

| Variant | Fields |
|---------|--------|
| Place | customerId: string, productIds: `array<string>` |
| Ship | — |
| Cancel | — |

---

## 7. Handling Both Approaches

The markdown format supports both aggregate and DCB approaches. The **approach** field in the plugin header determines which sections are expected:

| Section | Aggregate | DCB |
|---------|-----------|-----|
| Event Log | - | required |
| Aggregates + Behaviors | required | - |
| State Change Slices | - | required |
| State View Slices | - | optional |
| Automation Slices | - | optional |
| Outbound Translation Slices | - | optional |
| Inbound Translation Slices | - | optional |
| Read Models + Projections | optional | - |
| Event Mappings | optional | - |
| Side Effects | optional | - |
| Tasks | optional | - |
| Extension Points | optional | optional |
| Extensions | optional | optional |

---

## 8. Open Questions

1. **How much logic to capture?** The tables above capture structural decisions (which event → which action) but not arbitrary ReScript expressions. For simple CRUD-style components, the tables are complete. For components with complex business logic (e.g., discount calculations, multi-step validations), the markdown would need either:
   - A prose description of the logic (human-readable but not machine-generatable)
   - Embedded ReScript snippets (machine-parseable but defeats the purpose of markdown)
   - A restricted DSL for common patterns

2. **Versioning**: Should the markdown files track spec versions? The code uses semantic-release — the markdown could include a version header that's updated when specs change.

3. **Validation**: A CI step could run both directions (code → markdown → code) and diff the result to detect drift. This requires the round-trip to be deterministic for the lossless elements.

4. **GraphQL resolver config**: The `resolverConfig.fields` parameter in Behavior controls which fields are exposed in the auto-generated GraphQL API. This could be captured in the markdown but is rarely customized.

5. **ReadModel config**: Index definitions and sub-ID configs are infrastructure concerns. Include them in the markdown or treat them as deployment details?
