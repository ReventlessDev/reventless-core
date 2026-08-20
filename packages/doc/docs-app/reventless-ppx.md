# Reventless PPX Guide

The Reventless PPX eliminates boilerplate from application code. Instead of manually declaring `let name`, `module Id`, `let moduleUrl`, and `@s.matches(DcbTag.string)`, you add a single annotation and the PPX injects everything at compile time.

---

## Setup

Add the PPX to your package's `rescript.json`. It **must** come before `sury-ppx`:

```json
{
  "ppx-flags": ["@reventlessdev/reventless-ppx/bin", "sury-ppx/bin"]
}
```

The PPX reads `package.json` (for the npm package name) and `rescript.json` (for namespace and dependencies) from the nearest parent directory. Both files must exist.

---

## Annotations

### `@@reventless.spec`

Use on **all spec files**: aggregate specs, read model specs, extension point specs, DCB slice specs, event mapping specs, and side effect specs.

**What it injects:**
| Binding | Condition | Value |
|---------|-----------|-------|
| `let name` | Not already declared | Derived from filename |
| `module Id` | Not already declared, and `reventless-spec` is a dependency | `Reventless.Id.String` |
| `let moduleUrl` | Not already declared | Computed npm specifier |
| `open Reventless.ReadModel` + `let config` + `let subIdConfig` | Filename contains `ReadModel`, `@schema type state` present, `let config` not declared | ReadModel defaults |

**Name derivation** strips known component suffixes from the filename:

| Filename | Derived name |
|----------|-------------|
| `Category.res` | `"Category"` |
| `ProductsReadModel.res` | `"Products"` |
| `AddCategory.res` | `"AddCategory"` |
| `CategoriesView.res` | `"Categories"` |
| `Products_ExtensionPoint.res` | `"Products"` |
| `Product_Behavior.res` | `"Product"` |

Stripped suffixes (each tried first with a leading underscore, e.g. `_Behavior`, then bare): `ExtensionPointMapping`, `ExtensionPoint`, `ReadModel`, `Behavior`, `Projections`, `Projection`, `Aggregate`, `Plugin`, `Slice`, `Spec`, `View`.

**Dotted names in spec packages:** When the `rescript.json` namespace ends in `Spec` (e.g., `CatalogSpec`), the PPX automatically prefixes the derived name with the plugin name:

| Filename | Namespace | Derived name |
|----------|-----------|-------------|
| `Products_ExtensionPoint.res` | `CatalogSpec` | `"Catalog.Products"` |
| `Orders_ExtensionPoint.res` | `OrderingSpec` | `"Ordering.Orders"` |

The plugin name is the namespace with `Spec` stripped.

**Explicit name override:**

```rescript
@@reventless.spec("CustomName")
```

Use this when the derived name doesn't match your intent. The PPX still injects `module Id` and `moduleUrl`.

**`module Id` is skipped** when `reventless-spec` is not in the package's `rescript.json` dependencies. This allows lightweight spec packages (extension point specs) to use `@@reventless.spec` without depending on the full framework.

---

### `@@reventless.behavior`

Use on **all behavior files**.

**What it injects:**
| Binding | Condition | Value |
|---------|-----------|-------|
| `open Spec` | Not already present | Opens the spec module |
| `module Spec = Spec` | Not already declared | Aliases the spec module |
| `let moduleUrl` | Not already declared | Computed npm specifier |

**Spec module derivation:** strips `_Behavior` (or a bare `Behavior`) from the filename.

| Filename | Derived spec |
|----------|-------------|
| `Category_Behavior.res` | `open Category; module Spec = Category` |
| `Order_Behavior.res` | `open Order; module Spec = Order` |
| `ProductDemand_Behavior.res` | `open ProductDemand; module Spec = ProductDemand` |

**Explicit spec override:**

```rescript
@@reventless.behavior(PluginSpec)
```

Use this when the spec module name doesn't match `{Filename minus Behavior}` — for example when the spec file is named differently than the behavior file's prefix.

---

### `@@reventless.dcbTags`

Use on **DCB slice files** outside `*Slice/` folders that have entity ID fields in `@schema` types. Files inside any `*Slice/` folder (StateChangeSlice, StateViewSlice, AutomationSlice, InboundTranslationSlice, OutboundTranslationSlice) get dcbTags automatically via `@@reventless.spec` — no explicit `@@reventless.dcbTags` needed.

**What it does:** Scans all `@schema`-annotated variant types and injects `@s.matches(Reventless.DcbTag.string)` on fields that match these rules (unless `@s.matches(...)` is already present):

| Field pattern | Type | Injection |
|---|---|---|
| `*Id: string` | scalar | `@s.matches(DcbTag.string)` on the type |
| `*Id: array<string>` | array (singular name) | `@s.matches(DcbTag.string)` on the element type — for cross-entity queries |
| `*Ids: array<string>` | array (plural name) | `@s.matches(DcbTag.string)` on the element type — for multi-value storage |

The PPX generates the fully qualified `Reventless.DcbTag.string`, so no `open Reventless` is needed just for DCB tags.

**Before (manual):**
```rescript
@schema
type command = AddProduct({
  productId: @s.matches(DcbTag.string) string,
  name: string,
})

@schema
type event = ProductAdded({
  productId: @s.matches(DcbTag.string) string,
  name: string,
})
```

**After (with PPX):**
```rescript
@@reventless.dcbTags

@schema
type command = AddProduct({
  productId: string,
  name: string,
})

@schema
type event = ProductAdded({
  productId: string,
  name: string,
})
```

**Combine with `@@reventless.spec`:** Most DCB files outside slice folders use both annotations:

```rescript
@@reventless.spec
@@reventless.dcbTags
```

---

### `@partitionTag`, `@noDcbTag`, `@dcbTag` — field-level DCB tag control

These field attributes give fine-grained control over DCB tag injection. They work in any `@@reventless.spec` or `@@reventless.behavior` file, regardless of whether dcbTags auto-inference is active.

| Annotation | Placed on | Effect |
|---|---|---|
| `@partitionTag` | A `*Id: string` field | Injects `@s.matches(DcbTag.partition)` — marks this field as the partition key. Required when a variant has multiple `*Id` fields. |
| `@crossPartition` | A `string` (or `array<string>` element) field | Injects `@s.matches(DcbTag.crossPartition)`. **Rarely needed** — cross-entity *reference* reads are inferred from the slice graph; this is the escape hatch only for **M:N capacity** reads of a slice's own event type. See [`@crossPartition`](#crosspartition--cross-partition-secondary-tag-reads) below. |
| `@noDcbTag` | A `*Id: string` field | Suppresses auto-tagging — the field stays as plain `string`. Use when the field is payload data, not a DCB query key. |
| `@dcbTag` | Any `string` field | Injects `@s.matches(DcbTag.string)` — explicit opt-in for fields that don't follow `*Id` naming (e.g., `sku`, `slug`, `reference`). |

The PPX strips all four attributes from the output AST, so the compiler never sees them as unknown attributes.

**`@partitionTag` — multiple `*Id` fields:**
```rescript
// In a StateChangeSlice file — both productId and orderId would otherwise
// both get auto-tagged, making partition derivation ambiguous
@schema
type event =
  | DemandRecorded({
      @partitionTag productId: string,  // partition key
      orderId: string,                  // also tagged as DcbTag.string
    })
```

**`@noDcbTag` — payload-only field:**
```rescript
@schema
type event =
  | DemandRecorded({
      @partitionTag productId: string,
      @noDcbTag orderId: string,  // not a DCB tag — plain string in the event store
    })
```

**`@dcbTag` — non-`*Id` field name:**
```rescript
@@reventless.dcbTags

@schema
type event =
  | SkuAdded({
      @dcbTag sku: string,  // not *Id naming, but should be a DCB tag
      name: string,
    })
```

---

### `@compositePartitionTag` — composite DCB partition key

`@compositePartitionTag` lets you form the DynamoDB partition key from multiple fields, concatenated in declaration order with a configurable separator. Use it when a single field is too coarse for partitioning and a composite identity (e.g. `environment/platform/plugin`) distributes events better across partitions.

Each annotated field is still a regular DCB tag (individually queryable). The composite key is derived automatically at runtime from the stored tag values.

**Syntax:**

```rescript
@compositePartitionTag            // uses "/" after this field (default)
@compositePartitionTag("/")       // explicit default — identical behaviour
@compositePartitionTag(":")       // uses ":" after this field
```

The separator on the **last** annotated field is ignored (nothing follows it).

**Example — three-segment composite key `env/platform/plugin`:**

```rescript
@@reventless.spec

@schema
type event =
  | PluginSynced({
      @compositePartitionTag environment: string,   // partition: env/...
      @compositePartitionTag platformName: string,  // partition: env/platform/...
      @compositePartitionTag pluginName: string,    // last field — sep ignored
      version: string,
    })
// Composite partition key value: "{environment}/{platformName}/{pluginName}"
// Each field is also individually queryable as a DcbTag.string.
```

**Constraints:**

| Rule | Behaviour |
|---|---|
| Non-`string` field annotated | No-op — field is left untouched |
| `@compositePartitionTag` and `@partitionTag` on the same schema | `derivePartitionTag` throws at startup |
| Fewer than 2 fields annotated | `derivePartitionTag` throws at startup |
| A member's value is the empty string | Permitted — see below |

**Empty tag values.** A composite key often describes a hierarchy, and a member of
that hierarchy can be genuinely absent — an entity owned at the outer level has no
inner-level name to give. The framework accepts an empty tag value rather than
forcing a placeholder that fabricates identity:

- The event **records** the tag with its empty value, on every backend.
- The value **participates in the composite key** (`key:value` pairs joined with
  `#`), so the composite partition key, composite reads and the OCC fences all
  behave exactly as they do for a non-empty member.
- The value is **not individually indexed**. On DynamoDB each tag key gets a
  `tag_<key>` GSI whose hash key is that attribute, and a key attribute cannot hold
  an empty string — so the adapter skips the attribute and the index goes sparse
  (its intended mechanism). Reads by the *partition* are unaffected; they go against
  the base table.

The one consequence to design around: a `@crossPartition` read of a tag key resolves
through that per-tag index, so it never returns events whose value for that key is
empty (querying for an empty key value is not expressible in DynamoDB either). If a
value must be findable across partitions, it must be non-empty.

**Placement:** Place `@compositePartitionTag` **before the field name**, exactly like `@partitionTag`:

```rescript
// CORRECT
@compositePartitionTag environment: string

// WRONG — annotation on the type, not the field (silently ignored)
environment: @compositePartitionTag string
```

---

### `@crossPartition` — cross-partition (secondary-tag) reads

> **You usually don't need this.** When a slice reads *another entity's* lifecycle
> by its id (e.g. `AddProduct` checking a `categoryId` that `Category` owns), the
> framework **infers** the cross-partition read from the slice graph — declare the
> consumed events and the foreign field, and write no annotation. `@crossPartition`
> is the **escape hatch for the one case inference can't see**: an **M:N capacity**
> read where a slice reads its *own* event type by a secondary key across all of
> that key's partitions (below). A `@crossPartition` that the framework resolves as
> the slice's own partition is flagged as a contradiction at build time.

A DCB event is stored under exactly one **partition** (its `@partitionTag`). A
single-tag decision read of any *other* tag the event carries is, by default,
**partition-scoped** — it only sees events whose partition key is that tag, so a
tag that is secondary on the event is invisible to such a read.

`@crossPartition` opts a tag into a **cross-partition read**: a single-tag read
of that key returns **every** event carrying it across *all* partitions. This is
the canonical shape for an **M:N capacity invariant** — a slice both produces and
reads an event that ties two entities, partitioned by one, so it must also read by
the other; inference treats that own-stream read as partition-scoped, so you opt
in explicitly.

```rescript
// Course subscription: partition by courseId; studentId is read across every
// course partition the student appears in. The annotation goes on BOTH the
// command (its tags build the read query) and the produced event (its tags
// drive partitioning, GSI indexing, and the fence) — never on consumedEvent.
@schema
type command =
  | SubscribeStudent({
      @partitionTag courseId: string,      // → clause [courseId]  — partition read
      @crossPartition studentId: string,   // → clause [studentId] — cross-partition read
    })

@schema
type event =
  | StudentSubscribed({
      @partitionTag courseId: string,
      @crossPartition studentId: string,
    })
```

`SubscribeStudent` then builds **two single-tag reads** — "all of the course"
(by `courseId`) AND "all of the student" (by `studentId`) — instead of one
composite read of the exact `{course, student}` pair.

How it works under the hood (no slice-contract change beyond the annotation):

- **Read routing.** A `@crossPartition` clause reads the per-tag `tag_<key>` GSI
  (a `Query` for keys + a `BatchGet`/`GetItem` for payloads) instead of the
  base-table partition. GSI reads are eventually consistent — the append fence
  catches any staleness at commit, costing at most a retry.
- **Fence scope follows read scope.** A `@crossPartition` tag's consistency fence
  is bumped by **every** carrier (primary *or* secondary), so optimistic
  concurrency detects a concurrent secondary-tag writer. Partition-scoped tags
  keep the narrow "bump only your own partition" rule.

Notes and constraints:

- **Default is partition-scoped.** Leave the annotation off unless you genuinely
  need the cross-partition fold — it makes the tag's fence hotter (every writer
  of that tag contends on one fence) and the read O(entity degree). For capacity
  checks ("≤ N …"), bound the read with a count/limit rather than folding the
  whole set.
- **Scope is a property of the tag *key*** and must agree across every event type
  that carries it — the fence is driven by writers, so a key cannot be
  cross-partition for one producer and partition-scoped for another. `Dcb_Builder`
  reports a scope mismatch at build time.
- **Placement:** before the field name, like `@partitionTag`. Works on a `string`
  field or the element type of an `array<string>` field.

---

### `@noApi` — exclude commands from GraphQL/MCP exposure

Use on command types or individual command variants to exclude them from automatic GraphQL mutation and MCP tool generation.

| Annotation | Placed on | Effect |
|---|---|---|
| `@noApi` | `@schema type command` | Entire command type hidden from API |
| `@noApi` | A single variant in a command type | Only that variant hidden, others remain public |

**Type-level `@noApi` — entire command hidden:**
```rescript
// Driven by an extension reacting to another plugin's events — never by a client.
@schema @noApi
type command =
  | RecordDemand({@partitionTag productId: string, orderId: string})
  | RevokeDemand({@partitionTag productId: string, orderId: string})
```
All variants of this command type are excluded from GraphQL mutations and MCP tools. Use this for commands that only ever arrive from an extension, an automation, or another internal path.

**Variant-level `@noApi` — individual variants hidden:**
```rescript
@schema
type command =
  | CancelOrder({orderId: string})      // Public — exposed as GraphQL mutation + MCP tool
  | @noApi ReopenOrder({orderId: string})  // Internal — hidden from API
```

The `@noApi` annotation is stripped from the compiled output by the PPX. Filtering happens at schema generation time in `Plugin_Builder` (for Aggregates) and `Dcb_Builder` (for StateChangeSlices).

---

### `@lifecycle` — mark the field a record's lifecycle lives in

The field whose value identifies where the record is in its life: the enum a command's `@allowedStates` is written in terms of, the one a board draws its columns from, a progress tracker walks and a state diagram renders. AutoUI's command-menu filter reads it per row and matches it against each command's `@allowedStates` set.

There are two ways to declare it, and a record uses whichever fits.

**Name the field `lifecycle` and write nothing.** The name is the declaration:

```rescript
@@reventless.spec

@schema
type lifecycle = Placed | Shipped | Cancelled

@schema
type state = {
  orderId: string,
  customerId: string,
  lifecycle: lifecycle,
}
```

**Or annotate whatever the field is called**, for a record whose lifecycle field has an honest name of its own:

```rescript
@schema
type accountStatus = Active | Deactivated

@schema
type state = {
  customerId: string,
  @lifecycle accountStatus: accountStatus,
}
```

The PPX emits the annotated field name into `stateAnnotationSpec.lifecycle` (sury metadata attached to the state schema). Codegen reads it when building `queryableDef.lifecycleField`.

An enum-shaped field is not automatically a candidate. A `locationStatus: Pending | Located | Unresolvable` tracking a geocoder's progress is enum-shaped and named like a status, and annotating it would section the list by how far a background job got and filter the command menu against states no command mentions. The annotation is keyed on `lifecycle` rather than `status` for exactly this reason — a record often carries several statuses and at most one lifecycle.

**Resolution order** (codegen, `Plugin_Structure.lifecycleFieldFromStateSchema`): (1) field annotated `@lifecycle`; (2) field literally named `"lifecycle"` whose shape is an enum (a free-text `lifecycle: string` does not count — `@allowedStates` filtering needs states to compare against); (3) `None`, and the per-row filter is inert.

**Why the convention is keyed on `lifecycle` and not `status`.** `status` is a promiscuous name — geocoding progress, todo-queue progress, translation audit outcome and plugin connection state all wear it — so a convention keyed on it genuinely guesses, and guesses often. `lifecycle` is a deliberate word nobody types by accident, so matching it is close to reading a declaration written in the field name.

**A framework-generated row declares rather than following the convention.** Its field name is chosen by the framework and read by every client, so it is the wrong thing to make load-bearing: the platform's own Plugins read model keeps its published `status` field and annotates it.

**Constraint:** at most one `@lifecycle` per state record. The PPX errors on duplicate annotations within the same record.

**Renamed from `@status`.** The old spelling is a compile error naming this one; there is no alias, because a silently-accepted old name is exactly the ambiguity the rename removes.

---

### `@groupBy` — section the list view by a field

Use on a single `@schema type state` field in a ReadModel or StateViewSlice spec to mark the field the UI's list view should group rows by. AutoUI's list view renders the read model's rows in sections keyed on the annotated field, ordered by the field's `enum` declaration order when the field is an enum.

```rescript
@@reventless.spec

@schema
type kind = Domain | PlatformInfrastructure | Commercial | Marketplace

@schema
type state = {
  pluginId: string,
  name: string,
  @groupBy kind: kind,
}
```

The PPX emits the field name into `stateAnnotationSpec.groupBy` (sury metadata attached to the state schema), and `SuryToJsonSchema.deriveObjectSchema` stamps `x-reventless-group-by: true` on the named field of the read model's JSON Schema. The UI reads that extension property; there is no runtime or projection change — this is a schema hint only.

**Section ordering:** when the group field is an enum, the UI orders sections by the enum's declaration order. To change the section order, reorder the enum constructors — no UI change required.

**Constraint:** at most one `@groupBy` per state record. The PPX errors on duplicate annotations within the same record. Stacks with other field annotations (e.g. `@scan @groupBy kind: kind` makes the field both server-side filterable and the list section key).

---

### `@live` — declare the view's live-updates default

Use on the `@schema type state` **declaration** (not a field) of a ReadModel or StateViewSlice spec to declare whether live updates make sense for the view. `@live(false)` marks investigative/historical views (catalogues, comparisons, audit histories) where a live-updates control is pointless; `@live(true)` marks operational views where one should be offered.

```rescript
@@reventless.spec

@live(false)
@schema
type state = {
  @id productId: string,
  name: string,
}
```

The PPX emits the bool into `stateAnnotationSpec.live` (sury metadata attached to the state schema), and `SuryToJsonSchema.deriveObjectSchema` stamps top-level `x-reventless-live: bool` on the read model's JSON Schema. The framework only transports the declaration — UI consumers decide what to do with it (the annotation typically governs whether a Live control is offered at all). **Absent annotation ⇒ absent key ⇒ the consumer's own default applies.** There is no runtime or projection change — this is a schema hint only.

**Constraint:** the payload is exactly one bool literal (`@live(true)` or `@live(false)`); anything else is a compile error. Only ReadModel and StateViewSlice (incl. Stream) spec files accept it — the PPX errors on a `@live` state declaration in any other spec file.

---

### `@allowedStates` — per-variant command state guard

Use on individual command variants in an aggregate or DCB-slice `@schema type command` to declare which lifecycle states the command is meaningful in. The payload is an expression list of status-type constructor references. AutoUI hides the command on rows whose status isn't in the set.

```rescript
// In Order.res (an Order aggregate spec):
@@reventless.spec

@schema
type command =
  | Place({customerId: string, productIds: array<string>})
  | @allowedStates([Orders.Placed]) Ship
  | @allowedStates([Orders.Placed]) Cancel
```

| Annotation | Placed on | Effect |
|---|---|---|
| `@allowedStates([…])` | A single command variant | Variant is shown only on rows where the row's `lifecycleField` value is in the set |
| (no annotation) | A single command variant | Variant is always shown (back-compat default) |
| `@allowedStates([])` | A single command variant | Variant is never shown (defensive "never available" form) |

The PPX extracts each constructor's leaf identifier as a string and emits `let commandSchema = ReventlessInfra.Api.markAllowedStates(commandSchema, [|("Ship", [|"Placed"|]); …|])` attaching the per-variant map to the schema metadata. The wire format on `Platform_ComponentDefinitions` is `commandDef.allowedStates: option<array<string>>` — `None` means "always show", `Some([…])` means "filter".

**Supports payloadless and payload variants uniformly.** The PPX walks the attribute payload as syntactic AST and extracts the leaf identifier; it works for `Submitted` (payloadless), `OrdersStatus.Submitted` (qualified payloadless), `Shipped({trackingNumber})` (payload), and any combination. AutoUI's filter compares against the row's serialised status tag — sury emits payloadless variants as bare JSON strings and payload variants as `{TAG: …, …}` objects, both surfacing the constructor name.

**Limitation: no compile-time existence check.** The constructor name is extracted as a string without verifying the constructor actually exists on the read model's status type. A typo (`@allowedStates([Orders.Plased])`) compiles cleanly; the filter just never matches that string. ReScript's dependency analysis runs pre-PPX, so a witness-binding approach (emitting `let _ = Orders.Placed`) would force ReScript to build the witness's module first — which it doesn't see as a dep, breaking the build order. Runtime cross-validation against the status-field schema is captured as future work in `AllowedStatesAnnotation.ml`.

---

### `@id`, `@compositeId` — partition key derivation

Use on `@schema type state` fields in ReadModel and StateViewSlice spec files. The PPX generates `let makeId` from the annotated field(s). This replaces a manual `let makeId` declaration.

| Annotation | Usage | Generated code |
|---|---|---|
| `@id` | One `string` field | `let makeId = (state: state) => state.fieldName` |
| `@compositeId` | Multiple `string` fields | `` let makeId = (state: state) => `${state.f1}/${state.f2}/...` `` |
| `@compositeId(~sep=":")` | Multiple `string` fields, custom separator | Same with `:` between segments |

**`@id` — simple entity key:**
```rescript
@@reventless.spec

@schema
type state = {
  @id productId: string,
  name: string,
  price: float,
}
// PPX generates: let makeId = (state: state) => state.productId
```

**`@compositeId` — multi-segment key:**
```rescript
@@reventless.spec

@schema
type state = {
  @compositeId tenantId: string,
  @compositeId productId: string,
  name: string,
}
// PPX generates: let makeId = (state: state) => `${state.tenantId}/${state.productId}`
```

**Constraints:** `@id` and `@compositeId` cannot both appear on the same type. Both require `string` fields.

---

### `@subId`, `@compositeSubId` — sort key derivation

Use on `@schema type state` fields in ReadModel and StateViewSlice spec files. The PPX generates `let subIdConfig` from the annotated field(s). This replaces the default `let subIdConfig = None` injected by `@@reventless.spec`.

| Annotation | Usage | Generated code |
|---|---|---|
| `@subId` | One `string` field | `let subIdConfig = Some({ subIdField: "fieldName", getSubId: state => state.fieldName })` |
| `@compositeSubId` | Multiple `string` fields | Synthetic `_subId` attribute: `` let subIdConfig = Some({ subIdField: "_subId", getSubId: state => `${state.f1}/${state.f2}/...` }) `` |
| `@compositeSubId(~sep=":")` | Multiple `string` fields, custom separator | Same with `:` |

**`@subId` — version as sort key:**
```rescript
@@reventless.spec

@schema
type state = {
  @id productId: string,
  @subId version: string,
  name: string,
}
// Enables: productById(id: ID!): ProductByIdConnection!
//   with sort key args: prefix, from, to, eq, reverse, limit, nextToken
```

**`@compositeSubId` — composite sort key:**
```rescript
@@reventless.spec

@schema
type state = {
  @id orderId: string,
  @compositeSubId createdAt: string,
  @compositeSubId lineItemId: string,
  amount: float,
}
// PPX generates: let subIdConfig = Some({ subIdField: "_subId", getSubId: ... })
// Stored _subId value: "{createdAt}/{lineItemId}"
```

**Constraints:** `@subId` and `@compositeSubId` cannot both appear on the same type. `@subId` requires a `string` field.

---

### `@index`, `@indexSubId` — secondary index annotations

Use on `@schema type state` fields to declare DynamoDB secondary indexes. The PPX aggregates all index annotations and generates `let config` with an `indexes` array.

**`@index` — simple secondary index (no sort key):**
```rescript
@schema
type state = {
  @id productId: string,
  @index categoryId: string,
  name: string,
}
// secondary index: partition key = categoryId, ALL projection
// Query field generated:
//   ProductByCategoryId(categoryId: String!, first: Int, after: String,
//                       last: Int, before: String,
//                       includeRetired: Boolean): ProductConnection!
// Pages forward on first/after. `last`/`before` are declared but refused —
// the cursor is the store's forward-only continuation token, and both
// backends say so rather than answering the forward page.
```

**`@index` with projection options:**
```rescript
// KEYS_ONLY projection
@index({projection: "KEYS_ONLY"}) categoryId: string,

// INCLUDE projection
@index({projection: "INCLUDE", fields: ["name", "price"]}) categoryId: string,
```

**Named `@index` with `@indexSubId` — secondary index with sort key:**

Use the same name on both annotations to link them. The named index gets both a partition key and a sort key.

```rescript
@schema
type state = {
  @id productId: string,
  @index("byCategoryDate") categoryId: string,
  @indexSubId("byCategoryDate") createdAt: string,
  name: string,
}
// secondary index: partition = categoryId, sort = createdAt
```

**Composite secondary index keys** — annotate multiple fields with the same name:
```rescript
@schema
type state = {
  @id productId: string,
  @index("byTenantCategory") tenantId: string,
  @index("byTenantCategory") categoryId: string,  // composite pk: tenantId/categoryId
  @indexSubId("byTenantCategory") region: string,
  @indexSubId("byTenantCategory") createdAt: string,  // composite sk: region/createdAt
  name: string,
}
// Synthetic attributes injected at save: _byTenantCategory_pk, _byTenantCategory_sk
```

**Authorization — restrict secondary index access by Cognito group:**
```rescript
@index({group: "admin", authTable: "PlatformAuth"}) tenantId: string,
```

**Constraints:** `@indexSubId("name")` without a matching `@index("name")` is an error.

---

### `@resolves`, `@resolvesMany` — cross-table resolvers

Use on `@schema type state` fields to generate virtual GraphQL fields that resolve IDs to objects from another QueryDb table.

**`@resolves` — resolve a single ID to its object:**

```rescript
@schema
type state = {
  @id orderId: string,
  @resolves({table: "Products", field: "product"}) productId: string,
  quantity: int,
}
// Adds virtual GraphQL field: product: Product
// Resolved by GetItem on the Products table using productId
```

****`@resolves` via secondary index:**
```rescript
@resolves({table: "Orders", field: "currentOrder", via: "byProductId"}) productId: string,
// Resolved by querying Orders table's byProductId secondary index
```

**`@resolves` with cross-plugin table:**
```rescript
@resolves({table: "Products", field: "product", plugin: "CatalogPlugin"}) productId: string,
```

**`@resolvesMany` — resolve an array of IDs:**
```rescript
@schema
type state = {
  @id cartId: string,
  @resolvesMany({table: "Products", field: "products"}) productIds: array<string>,
}
// Adds virtual GraphQL field: products: [Product!]!
// Resolved by BatchGetItem on the Products table
```

**Note:** `@resolves` and `@resolvesMany` use **record payload syntax** (`({key: "value"})`), not labeled-arg syntax. The keywords `~to` and `~as` are reserved in ReScript and cannot be used as labeled args.

---

### `@storageRef`, `@offload` — object-store field markers

These field markers declare that a field's value lives in one of the platform's object stores, and provision that store. Place them **before the field name** (like the DCB tag markers).

**`@storageRef` — a field holding a store ref (`string` / `array<string>`):**

The value is a store-minted origin-relative path; the ref *is* the value the reader renders. `@storageRef("store")` names a store of this plugin; `@storageRef("Plugin.store")` points at another plugin's.

```rescript
@schema
type command =
  | ChangeProductImage({
      @dcbTag productId: string,
      @storageRef("productImages") imageUrl: string,
    })
```

**`@offload` — an inline-or-reference field:**

A small value stays embedded in the command/event; a large one is content-addressed to the store by the **client** (which uploads the bytes before issuing the command) and carried as a reference — so the event shrinks and byte-identical values across versions dedupe to one object. A reader resolves either arm back to the value with `Offload.resolve`.

```rescript
@schema
type event =
  | ReportGenerated({
      reportId: string,
      @offload("reports") body: option<reportBody>,
    })
```

- Forms: `@offload("store")`, `@offload("plugin.store")`, and the record form `@offload({store: "store"})`; works on a field of type `X` or `option<X>`.
- **Per-field threshold:** `@offload({store: "s", threshold: 16384})` sets the inline-vs-offloaded byte cut. A client resolves the effective cut with `Offload.effectiveThreshold` — precedence **per-field marker → platform default → 8 KB** — and passes it to `Offload.prepare` when uploading. Retuning it is always safe; it only changes how *future* values split.

**Constraints:** the field's inner type must be a plain named type (`reportBody`, `M.t`); for an `array<…>` or type-parameterised inner type, apply the schema by hand with `@s.matches(Reventless.Offload.optionSchema(~store="s", <schema>))`.

### `@owner` — the field that ties a row to its caller

`@owner` names the field holding the id of the principal a record belongs to. It goes on a field of a `@schema type command` variant, a `@schema type state`, or both. Place it **before the field name**, like the other field markers.

Two things follow, both enforced server-side:

- **On a command:** the framework **overwrites** the field with the authenticated caller's id before publishing. An absent field and a forged field therefore produce the same row — the client's value is ignored, not trusted.
- **On a queryable's state:** reads of that view are narrowed to the caller's own rows, on every transport.

```rescript
// StateChangeSlice/PlaceOrder.res
@schema
type command =
  PlaceOrder({
    @partitionTag orderId: string,
    @noDcbTag @owner customerId: string,
  })

// StateViewSliceStream/Orders.res
@schema
type state = {
  orderId: string,
  @owner customerId: string,
  lifecycle: lifecycle,
}
```

- **One per record or variant payload.** A second `@owner` is a compile error: every reader resolves the owner by taking the first marked field, so the second would be inert and the view would scope on whatever declaration order happened to put first.
- **`string` or `option<string>` only.** A row has one owner, so an array field cannot be one — annotating it is a compile error rather than a marker no reader looks at. The `f?: string` form works too.
- **It composes; it never subtracts.** The marker is applied after the DCB-tag passes and wraps whatever schema the field already resolved to, so an owner field keeps its DCB tag (`@owner customerId` in a slice), its partition key (`@partitionTag @owner`), or its reference (`@ref("Seller") @owner`). Use `@noDcbTag` when the owner field is payload rather than a query key.

**Who is exempt** is deployment configuration, not part of the annotation: a caller whose group is listed in `REVENTLESS_ELEVATED_GROUPS` is neither stamped nor scoped, and an internal system caller is exempt too. A deployment that declares `@owner` and configures no elevated groups is warned per view at startup — otherwise its operators would silently see only their own rows.

---

### `@retired` — what withdraws a row from ordinary reads

`@retired` names what means *this row is retired from ordinary use* — a deactivated customer, an archived category. Place it **before the field name**, on a `@schema type state` field of a ReadModel or StateViewSlice spec.

It has two forms, and which one is right depends on whether the record has a lifecycle.

**The boolean form** — the field is a flag, and the row is retired when it is `true`:

```rescript
@schema
type state = {
  @id customerId: string,
  displayName: string,
  @retired deactivated: bool,
}
```

**The state form** — the field is the record's `@lifecycle`, and the row is retired in one of its states:

```rescript
@schema
type accountStatus =
  | Active
  | Deactivated

@schema
type state = {
  @id customerId: string,
  @displayName email: string,
  @retired(Deactivated) @lifecycle accountStatus: accountStatus,
}
```

**Reach for the state form whenever the record has a lifecycle at all**, and the reason is what it does to commands. Without it, a record whose retirement is part of its life carries the same fact twice — once as the boolean the query layer filters on, once as a value of the enum that board columns, group sections, the progress tracker and `@allowedStates` are all expressed in terms of. Two sources of one truth, free to drift, with no rule keeping them in step.

With one field, `@allowedStates` becomes the command-applicability mechanism with no new annotation at all:

```rescript
| @allowedStates([Active]) UpdateEmail({email: string})
| @allowedStates([Active]) Deactivate
| @allowedStates([Deactivated]) Reactivate
```

That last line is the point. A consumer filtering a per-row command menu against `allowedStates` already exists and already works; what was missing was never a way to describe a command's stance on retirement — it was retirement being expressible in the vocabulary that stance is already written in.

The boolean form stays the right choice where retirement genuinely *is* a flag rather than a state: a `Products` view with an `archived` boolean and no lifecycle should not have to invent a two-valued enum.

Two things follow from the one annotation, and the second is why this is not a presentation hint like `@groupBy`:

- **On the schema:** `SuryToJsonSchema.deriveObjectSchema` stamps `x-reventless-retired: {label?, showWhenFalse, value?}` on the named property, so a consumer renders retirement as a *state of the row* rather than as one more data column. `value` is present only in the state form, and its absence is what tells a consumer which form the view declared.
- **On every read:** rows that are retired — the flag true, or the field equal to the named state — are withheld from callers who are not exempt — the list query, the single-entity query, the by-ids and by-index doors, and the payload of a live change frame. Codegen carries the field name as `queryableDef.retiredField` and the state as `retiredValue`, so a client holding the def holds the whole predicate; it is pushed into SQL and into the DynamoDB `FilterExpression` rather than applied to the returned page, so `first: 2` yields two live rows.

**Payload forms.** Bare, a state constructor, a string label, or a record:

```rescript
@retired deactivated: bool,
@retired(Deactivated) accountStatus: accountStatus,
@retired("Archived") archived: bool,
@retired({label: "Archived", showWhenFalse: true}) archived: bool,
@retired({value: Deactivated, label: "Closed"}) accountStatus: accountStatus,
```

The state is a **constructor reference**, not a string literal, matching `@allowedStates` — the two annotations name states in the same vocabulary, which is the whole reason the state form exists. A string would read the same and check nothing; what survives the constructor reference (a value that is not one of the field's declared cases) is reported when the plugin structure is built, where the schema is in hand.

The label defaults to empty, which the schema emitter omits so a consumer can tell "not stated" from "stated as empty" and derive one from the field name. `showWhenFalse` defaults to `false` and always travels: it asks a consumer to surface the flag in its negative state too, and since a non-exempt caller never receives a retired row, a default-on marker would appear on every row they can read and carry no information.

- **One per state record.** A second `@retired` is a compile error. Two retirement flags do not narrow the read further, they leave it undecided — the query layer tests a single field.
- **The field type check inverts on the payload.** With no state named, the field must be `bool` or `option<bool>` (the `f?: bool` form works too) — the predicate is "is this true?", and on a non-boolean there is nothing to evaluate. With a state named, the field must NOT be a boolean, because it holds the enum that state belongs to. Either mistake is a compile error with the message for that branch; getting it wrong would leave the annotation riding the schema, rendering as a marker and narrowing nothing.
- **The state form must sit on the record's `@lifecycle` field.** A retirement state anywhere else keeps the read narrowing but loses the command filtering that motivates it, because `@allowedStates` is written in terms of the lifecycle field — a state no command can name. Reported when the structure is built, along with a state the field does not declare.
- **Absent means not retired**, on all four backends. A row written before the annotation existed carries no flag, and excluding those would empty the view the day someone adds `@retired`.
- **Annotation or nothing.** Unlike `@lifecycle`, there is no conventional fallback: a boolean named `archived` that nobody annotated stays exactly as visible as it was. Guessing wrong here makes rows disappear.

**Reaching the archive.** A list query gains an `includeRetired: Boolean` argument, honoured **only** for a caller who was going to be allowed those rows anyway; a scoped caller passing it is ignored rather than refused. Note that elevation alone does not lift the restriction — an exempt caller is excluded until they ask, because an archive that is always underfoot is not an archive.

**Who is exempt** is the same deployment-wide `REVENTLESS_ELEVATED_GROUPS` that `@owner` uses, and deliberately so: two views must not disagree about who an operator is. There is no per-annotation elevation list.

**`@retired` neither needs nor implies `@scan`.** `@scan` widens the *client's* filter surface; this predicate is the resolver's, derived from who the caller is. A `<field>Eq` on the filter input would only ever return an empty page for the callers who could pass it.

**Cost.** An equality predicate over an enum-valued attribute indexes exactly as one over a boolean does, so nothing below changes between the two forms. The framework warns at deploy time when the annotated field keys no index, mirroring the `@owner` warning and for the same pathology: a `FilterExpression` is applied after the page is read, so pages shrink as the archive's share of the table grows. It warns rather than refuses — a small table may legitimately accept the cost. `@scan` deliberately does not silence it: it adds no index and removes no read unit.

**Live updates.** The state-change channel is keyed by view and entity and shared by every subscriber, so a publish cannot be scoped per caller. A save that leaves the row retired therefore publishes **metadata only** — `Updated` with no `state` — which asks every subscriber to refetch and lets the query layer answer for each of them. Un-retiring publishes full state as before. A subscriber still learns that *an entity with a given id changed*; removing that residual would need per-caller channels.

---

### Tagged unions as state fields

A variant held by a `@schema type state` field is one fact with several shapes, and it is the honest
alternative to several fields that nothing keeps in step:

```rescript
@schema
type geolocation =
  | Pending({requestedFor: string})
  | Located({point: Reventless.GeoPoint.t})
  | Unresolvable({reason: string})

@schema
type state = {
  @id customerId: string,
  geolocation: geolocation,
}
```

The value is stored as sury encodes it — `{"TAG":"Located","point":{…}}` — and reaches GraphQL as a
union with one object type per arm. Consumers select it with inline fragments
(`... on Ordering_CustomersGeolocationLocated { point { lat lng } }`), never bare.

**There is no annotation to write.** Inside a ReadModel or StateViewSlice spec, the PPX names the
union on its schema — `<Plugin>_<Spec><Type>`, the same shape the enum beside it is already
emitted under — and every member type is that name plus the arm's own. The name has to live on the
schema because two halves of the framework need it and neither can derive it from the other: the SDL
emitter reaches a field through a path, and the write path, which stamps each stored value with the
`__typename` GraphQL resolves the member by, has only the schema in hand. Elsewhere — a union
declared in a framework module, say — the same line is written by hand:

```rescript
let geolocationSchema = Reventless.TaggedUnion.named(~name="Geolocation", geolocationSchema)
```

A union with no name is not emitted as one: the field falls back to `String`, and the deploy log
names the view and the field so it is not silent.

**Every arm must declare at least one named field.** Three shapes are compile errors, and all three
compile, encode and decode perfectly well — what refuses them is GraphQL:

| Refused | Why |
|---|---|
| `\| Pending` | payload-less, so it is the bare string `"Pending"` on the wire; a union member must be an object type |
| `\| Pending({})` | an object, but the member type it implies has zero fields, which is invalid |
| `\| Located(GeoPoint.t)` | its field is published under the compiler's name `_0` — in the SDL, in the stored row, and in every consumer's query |

The pressure this creates is usually productive: an arm that seems to carry nothing normally carries
*when*, or *what it was trying*, and the declaration is the right place to be asked.

**An enum is untouched.** A variant whose arms all carry nothing is an enum, emitted as one, and none
of the above applies to it.

**Keys, filters, sorts and predicates are refused on a union field**: `@id`, `@subId` (and the
composite forms), `@index`, `@indexSubId`, `@scan`, `@scanSort`, `@groupBy`, `@lifecycle` and
`@retired` — including `@retired` on an arm. All of them end up comparing the field to a scalar,
and this field's value is an object whose shape depends on the row. The comparison would compile,
publish a filter input, and never match. Put the annotation on a scalar field beside the union.
"List the rows whose geolocation is `Unresolvable`" wants a derived arm-name field beside the union,
not a filter over it.

**Command and event variants are unaffected.** They are decomposed into one mutation per constructor,
so a payload-less command like `Deactivate` stays exactly as it is.

---

## Examples

### Aggregate spec

```rescript
// Category.res
@@reventless.spec

@schema
type command =
  | Add({name: string})
  | Rename({name: string})
  | Archive

@schema
type event =
  | Added({name: string})
  | Renamed({name: string})
  | Archived

@schema
type error =
  | CategoryAlreadyExists
  | CategoryNotFound
  | CategoryAlreadyArchived
```

PPX injects: `let name = "Category"`, `module Id = Reventless.Id.String`, `let moduleUrl = "..."`.

### Behavior

```rescript
// CategoryBehavior.res
@@reventless.behavior

@schema
type state =
  | NotCreated
  | Active({name: string})
  | Archived

let initialState = NotCreated

let evolve = (state, event) =>
  switch (state, event) {
  | (NotCreated, Added({name})) => Active({name: name})
  | (Active(_), Renamed({name})) => Active({name: name})
  | (Active(_), Category.Archived) => Archived
  | _ => state
  }

let decide = (state, command) =>
  switch (state, command) {
  | (NotCreated, Add({name})) => Ok([Added({name: name})])
  | (Active(_), Add(_)) => Error(CategoryAlreadyExists)
  | (Active(_), Archive) => Ok([Category.Archived])
  | (Archived, Archive) => Ok([]) // idempotent
  | _ => Error(CategoryNotFound)
  }
```

PPX injects: `open Category`, `module Spec = Category`, `let moduleUrl = "..."`.

### Read model spec

```rescript
// CategoriesReadModel.res
@@reventless.spec

@schema
type state = {
  name: string,
  archived: bool,
}
```

PPX derives: `let name = "Categories"` (strips `ReadModel` suffix). Because the filename contains `ReadModel` and the file has `@schema type state` with no `let config`, the PPX also auto-injects:

```rescript
open Reventless.ReadModel
let config = config()
let subIdConfig = None
```

To override, declare `let config` explicitly — the PPX skips injection when `let config` is present.

### Extension point spec (in a `*Spec` package)

```rescript
// Products_ExtensionPoint.res (in CatalogSpec namespace)
@@reventless.spec

@schema
type command = unit

@schema
type event =
  | ProductBecameAvailable({productId: string, name: string, price: float})
  | ProductPriceChanged({productId: string, price: float})

@schema
type directive = unit
```

PPX derives: `let name = "Catalog.Products"` (namespace `CatalogSpec` → `"Catalog"` + filename → `"Products"`). No `module Id` injected (no `reventless-spec` dependency).

### DCB StateChangeSlice

```rescript
// AddCategory.res
@@reventless.spec
@@reventless.dcbTags

type state = {exists: bool, archived: bool}

let initialState = {exists: false, archived: false}

@schema
type consumedEvent =
  | CategoryAdded
  | CategoryArchived

let evolve = (state, event) =>
  switch event {
  | CategoryAdded => {exists: true, archived: false}
  | CategoryArchived => {...state, archived: true}
  }

@schema
type command = AddCategory({categoryId: string, name: string})

@schema
type error = CategoryAlreadyExists

@schema
type event = CategoryAdded({categoryId: string, name: string})

let decide = (state, command) =>
  switch command {
  | AddCategory({categoryId, name}) =>
    if state.exists {
      Error(CategoryAlreadyExists)
    } else {
      Ok([CategoryAdded({categoryId, name})])
    }
  }
```

PPX injects `let name = "AddCategory"`, `module Id`, `let moduleUrl`, and `@s.matches(Reventless.DcbTag.string)` on the `categoryId` fields in both `command` and `event` types.

---

## Conventions

### PPX ordering

`reventless-ppx` **must** come before `sury-ppx` in `ppx-flags`. The reventless PPX injects `@s.matches` annotations that sury-ppx then processes into schema code.

### Namespace conventions

| Package type | Namespace pattern | Effect on name derivation |
|-------------|-------------------|--------------------------|
| Spec package | `CatalogSpec` | Dotted names: `"Catalog.Products"` |
| Plugin package | `CatalogPlugin` | Simple names: `"Category"` |
| Platform package | `true` or custom | Simple names |

### When to use explicit names

Use `@@reventless.spec("ExplicitName")` when:
- The desired name differs from the filename (rare)
- The file is a framework-internal component (e.g., `PluginSpec.res` → `"Plugin"` works, but being explicit is clearer)

Use `@@reventless.behavior(SpecName)` when:
- The spec module name doesn't match `{filename minus Behavior}` (e.g., `PluginBehavior.res` opens `PluginSpec`, not `Plugin`)

### Files that cannot use PPX annotations

These patterns cannot be auto-generated:

- `moduleUrl` for ExtensionPoint inline modules inside functor bodies — requires top-level `%raw` captured by closure
- Spec definitions inside inner modules in test fixtures

For these cases, use the manual declarations.

---

## `@@reventless.mappings`

File-level attribute on `<Plural>_Projections.res` (multi-source ReadModel projections in `ReadModel/`) and `<Entity>_Mappings.res` (Aggregate event-mapping siblings in `Aggregate/`).

**What it injects** (at the top of the file):
| Binding | Condition | Value |
|---------|-----------|-------|
| `open Reventless.<Domain>` | Not already opened | `Projection` (in `ReadModel/`) or `EventMapping` (in `Aggregate/`) or `AutomationSlice` (in `AutomationSlice/`) |
| `open Reventless.Message` | In `ReadModel/` and not already opened | — |
| `module Target` | Not already declared | Alias to the spec module (`<Stem>` with `_Mappings` / `_Projections` suffix stripped) |
| `module M` | Not already declared | `Reventless.<Domain>.Mappings.Make(Target)` |
| `module type Mapping` | Not already declared | `M.Mapping` |
| `let moduleUrl` | Not already declared | Computed npm specifier |
| `let counter = None` | In `Aggregate/` and not already declared | — |

The PPX also scans inner modules: any `module X = { ... }` containing both `let name = "..."` and `@schema type event` is treated as a DCB Source — `module Id = Reventless.Id.String` is injected (if absent) and dcbTags are applied to the event type's `*Id` fields.

**Before (manual):**
```rescript
open Reventless.Message
open Reventless.Projection

module ProductMapping = Mapping.Make(
  Product,
  Products,
  {
    open Product
    let project = ({event, id, _}) =>
      switch event {
      | Added({name}) => Set(id, {Products.name: name})
      | _ => Ignore
      }
  },
)

module M = Mappings.Make(Products)
module type Mapping = M.Mapping
let moduleUrl: string = %raw(`import.meta.url`)
let mappings: array<module(Mapping)> = [module(ProductMapping)]
```

**After (with PPX):**
```rescript
@@reventless.mappings

module ProductMapping = Mapping.Make(
  Product,
  Products,
  {
    open Product
    let project = ({event, id, _}) =>
      switch event {
      | Added({name}) => Set(id, {Products.name: name})
      | _ => Ignore
      }
  },
)

let mappings: array<module(Mapping)> = [module(ProductMapping)]
```

The plugin generator references the projections module directly: `module ProductsReadModel = Platform.ReadModel.Make(Products, Products_Projections)`. No more `@reventless.projections` wrapper module in `Plugin.res`.

---

## `@reventless.delegate`

Use on **`Delegate` module bindings** outside `*ExtensionPointMapping*` files that need the same auto-transformation. Inside `*ExtensionPointMapping*` files, any module named `Delegate` is auto-transformed by `@@reventless.spec` without this attribute. Works at any nesting depth.

**What it injects** (into the module body):
| Binding | Condition | Value |
|---------|-----------|-------|
| `module Id` | Not already declared | `Reventless.Id.String` |
| `@schema type command = unit` | Not already declared | Sury generates `commandSchema` from this |
| dcbTags on `@schema type event` | Event type present | `@s.matches(Reventless.DcbTag.string)` on `*Id: string` fields |
| `@schema type error = unit` | Not already declared | Sury generates `errorSchema` from this |
| `let moduleUrl` | Not already declared | Computed npm specifier |

**Before (manual):**
```rescript
module Delegate = {
  let name = "CatalogEventLog"
  module Id = Id.String
  @schema type command = unit
  @schema
  type event =
    | ProductAdded({productId: @s.matches(DcbTag.string) string, name: string, price: float})
    | ProductPriceChanged({productId: @s.matches(DcbTag.string) string, price: float})
  @schema type error = unit
  let commandSchema = S.unit
  let moduleUrl: string = %raw(`import.meta.url`)
}
```

**After (with PPX):**
```rescript
@reventless.delegate
module Delegate = {
  let name = "CatalogEventLog"
  @schema
  type event =
    | ProductAdded({productId: string, name: string, price: float})
    | ProductPriceChanged({productId: string, price: float})
}
```

The developer only writes `let name` and the `@schema type event`. Everything else is auto-generated. The `@s.matches(Reventless.DcbTag.string)` annotation is applied automatically to `*Id: string` fields via the same logic as `@@reventless.dcbTags`.

---

## What the PPX replaces

| Before (manual) | After (PPX) |
|-----------------|-------------|
| `open Reventless` | (not needed for specs — `module Id` uses fully qualified path) |
| `module Id = Id.String` | Auto-injected by `@@reventless.spec` |
| `let name = "Category"` | Derived from filename |
| `let moduleUrl: string = %raw(\`import.meta.url\`)` | Computed at compile time |
| `open Spec; module Spec = Spec` | Auto-injected by `@@reventless.behavior` |
| `@s.matches(DcbTag.string)` on `*Id`/`*Ids` fields | Auto-injected by `@@reventless.dcbTags` (or automatically in `*Slice/` folders) |
| `@s.matches(DcbTag.partition)` on partition key field | Use `@partitionTag` field annotation |
| `@s.matches(DcbTag.string)` on non-`*Id` field | Use `@dcbTag` field annotation |
| Suppress auto-tagging on a `*Id` field | Use `@noDcbTag` field annotation |
| `module M = Mappings.Make(...)` + boilerplate | Auto-injected by `@@reventless.mappings` (file-level) |
| `open Reventless.ReadModel; let config = config(); let subIdConfig = None` | Auto-injected by `@@reventless.spec` for `*ReadModel*` files |
| `module Id`, `@schema command/error = unit`, `@s.matches`, `moduleUrl` in Delegate | Auto-injected in `*ExtensionPointMapping*` files; use `@reventless.delegate` elsewhere |
| `let makeId = ...` in ReadModel/StateViewSlice spec | Use `@id` or `@compositeId` on `@schema type state` fields |
| `let subIdConfig = Some({...})` in ReadModel/StateViewSlice spec | Use `@subId` or `@compositeSubId` on `@schema type state` fields |
| `let config = config(~indexes=[...])` with manual `indexConfig` records | Use `@index`/`@indexSubId` on `@schema type state` fields |
| Manual `idResolverConfig`/`idsResolverConfig` entries in `let config` | Use `@resolves`/`@resolvesMany` on `@schema type state` fields |
| Hand-written `@s.matches(StorageRef.forStore(...))` / `@s.matches(Offload.optionSchema(...))` | Use `@storageRef` / `@offload` field annotations |
| Hand-written `@s.matches(Owner.string)` on the caller-identifying field | Use the `@owner` field annotation |
