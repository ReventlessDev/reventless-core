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

When the partition key should be formed from multiple fields **joined in declaration order**, use the `@compositePartitionTag` **field-level** PPX annotation (before the field name, not after the colon) instead of writing `@s.matches` manually:

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

**Use `S.nullAsOption` instead** — it creates `T | null` with no `undefined`:

```rescript
let myOptionSchema = S.nullAsOption(baseSchema)
```

Do not hand-bind `js_nullable` through `sury/src/Sury.res.mjs`: that module no longer
ships, so such an external is a runtime-missing import the compiler cannot see. The
function survives, re-exported from `"sury"` as `nullable`, and `S.nullAsOption` is the
ReScript binding to reach for.

## Codecs: declare the shape, don't hand-write transforms

Build a codec from **`S.object` / `S.shape`** rather than a hand-written
`S.transform` parser/serializer pair wherever the shape can be declared. A transform
is opaque to sury: it cannot know what the arm accepts, so it must offer every value
to the arm's own serializer and let it reject. In a union that costs correctness, not
just speed:

- an absent optional value reaches the arms as a raw `undefined`, and the first
  serializer to read its payload dereferences it — an uncatchable `TypeError`,
  not a `SuryError`;
- a `json`-typed arm cannot chain into a non-JSON target, so a value that encodes
  fine to `S.json` throws when encoded to `S.jsonString`.

```rescript
// Untagged either-or: a sentinel-keyed reference OR the bare inline value.
let referenceArm = S.object(s => Offloaded(s.field("$offload", offloadedRefSchema)))
let inlineArm = inner->S.shape(value => Inline(value))
S.union([referenceArm, inlineArm])
```

One transform arm is enough to bring both failures back, so this is all-or-nothing
per union. A declared arm also stays **visible to schema walkers** — introspection,
healing, and the required-scalar tripwire all see through it, and see nothing through
a transform.

See `Offload` in reventless-spec for the worked example, and
`docs/analysis/done/sury-rc0-optional-union-encode.md` for the measurements.

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
