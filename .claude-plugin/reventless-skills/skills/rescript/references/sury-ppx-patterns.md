# Sury PPX Serialization Patterns

## Basics

The `@schema` attribute generates JSON serialization/deserialization code via the sury PPX:

```rescript
@schema
type event =
  | Added({name: string, price: float})
  | Removed({id: string})
```

This generates a `eventSchema` value of type `S.t<event>` that can encode/decode JSON.

## Schema Naming Convention

| Type name | Generated schema name |
|-----------|----------------------|
| `type t` | `schema` (NOT `tSchema`) |
| `type event` | `eventSchema` |
| `type command` | `commandSchema` |
| `type myCustomType` | `myCustomTypeSchema` |

**Important:** For `type t`, the generated name is just `schema`, not `tSchema`.

## @s.matches for DCB Tag Filtering

In DCB (Dynamic Consistency Boundary) types, entity ID fields must be tagged with `@s.matches(DcbTag.string)` for the framework to filter events by entity:

```rescript
@schema
type command = AddProduct({
  productId: @s.matches(DcbTag.string) string,
  name: string,
  price: float,
})
```

**Placement is critical:** The `@s.matches` annotation goes on the **type expression** (after the colon), NOT on the field name:

```rescript
// CORRECT — annotation on the type
productId: @s.matches(DcbTag.string) string

// WRONG — annotation on the field (silently ignored by PPX!)
@s.matches(DcbTag.string) productId: string
```

Both command AND event types need `@s.matches` on entity ID fields. Without it, queries return ALL events and the decision model sees phantom state from other entities.

### Composite partition keys

When the partition key should be formed from multiple fields, use the `@compositePartitionTag` **field-level** PPX annotation (before the field name, not after the colon) instead of writing `@s.matches` manually:

```rescript
// PPX annotation — recommended
@@reventless.spec
@schema
type event =
  | PluginSynced({
      @compositePartitionTag environment: string,
      @compositePartitionTag platform: string,
      @compositePartitionTag plugin: string,
      version: string,
    })

// Equivalent hand-written @s.matches (what the PPX generates):
@schema
type event =
  | PluginSynced({
      environment: @s.matches(DcbTag.compositePartitionMember(~position=0, ~sep="/")) string,
      platform:    @s.matches(DcbTag.compositePartitionMember(~position=1, ~sep="/")) string,
      plugin:      @s.matches(DcbTag.compositePartitionMember(~position=2, ~sep="/")) string,
      version: string,
    })
```

Each composite field is still a regular `DcbTag.string` — individually queryable. The runtime joins the tag values with their separators to form the DynamoDB partition key (`"prod/acme/billing"`).

## Cross-Entity Queries

When a command references multiple entities (e.g., an order referencing multiple product IDs), annotate array element types:

```rescript
@schema
type command = PlaceOrder({
  orderId: @s.matches(DcbTag.string) string,
  lineItems: array<@s.matches(DcbTag.string) string>,
})
```

The runtime auto-detects arrays and builds multi-clause OR queries.

## Payload-Less Variants

Variants without payloads serialize as bare JSON strings, not objects:

```rescript
@schema
type event =
  | Activated     // serializes as "Activated" (string)
  | Renamed({name: string})  // serializes as {"TAG": "Renamed", "name": "..."}
```

This is fully supported by `Message.splitMessage`/`combineMessage`.

## Nullable Fields

**`S.nullableAsOption` fails `jsonableValidation` inside union variants** because it creates `T | undefined | null` — sury rejects `undefined` when the parent is not an `object`.

**Use `js_nullable` instead:**

```rescript
// Binding to sury's js_nullable (creates T | null, no undefined)
@module("sury/src/Sury.res.mjs")
external _jsNullable: (S.t<'a>, unit) => S.t<option<'a>> = "js_nullable"

let myOptionSchema = _jsNullable(baseSchema, ())
```

ReScript omits the `unit` arg in JS output, so `js_nullable(schema)` is called with `undefined` for `maybeOr` — correct behavior.

## Required Module URL

Spec files that the framework dynamically imports need a `moduleUrl` declaration:

```rescript
let moduleUrl: string = %raw(`import.meta.url`)
```

This is required for:
- Aggregate specs
- StateChangeSlice specs
- ExtensionPoint mapping modules
- Extension mapping modules
- SideEffect handler modules

## Id Types

```rescript
// Abstract ID (sealed — cannot construct from plain string)
module Id = ReventlessSpec.Id.String
// Create: Id.String.makeFromString("my-id")

// Transparent ID (for tests — string identity)
module Id = Id.StringPure
// Can use plain strings as IDs in test code
```

**Rule:** Use `Id.StringPure` in test specs; use `Id.String` in production specs.

## Pulumi Output Type

Infrastructure values are wrapped in `Pulumi.Output.t<'a>`:

```rescript
// StackReference output typing
let output: Pulumi.Output.t<option<JSON.t>> = stackRef->getOutput("key")

// Apply (transform inside Output)
output->Pulumi.Output.apply(value => {
  // value is unwrapped here
  processValue(value)
})
```

**Gotcha:** `getOutput` returns `Output.t<option<'a>>` — annotate as `Output.t<option<JSON.t>>` to unify with sury parsing.
