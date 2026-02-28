# Sury vs Effect Schema — Analysis

**Status:** Analysis (no implementation planned)

**Created:** 2026-02-28

**Summary:** Feature comparison of `sury` (the library currently used in Reventless for JSON
serialization and DCB tag extraction) against `effect/Schema` (the TypeScript schema module
bundled into the Effect ecosystem). Evaluates feasibility of replacing sury with Effect Schema
for the same use cases, with particular attention to GraphQL SDL generation from ReScript type
schemas.

**Verdict up front:** Replacing sury with Effect Schema does not make sense at this time.
Effect Schema is a TypeScript-only library with no ReScript PPX, no ReScript bindings, and
no GraphQL generation capability. The one genuine opportunity — type-driven GraphQL SDL
generation — can be addressed on top of sury without any library change.

---

## 1. How Sury Is Currently Used in Reventless

Sury serves three distinct roles in the codebase, which any replacement must match:

### 1.1 JSON Serialization / Deserialization

The vast majority of sury usage (~112 files) is plain encode/decode:

```rescript
// Annotate a type — sury-ppx generates `eventSchema: S.t<event>` at compile time
@schema
type event =
  | ItemCreated({itemId: string, name: string})
  | ItemRenamed({itemId: string, newName: string})

// Encode typed value → JSON
let json = event->Message.encode(Spec.eventSchema)
// ↳ calls S.reverseConvertToJsonOrThrow(eventSchema)

// Decode JSON → typed value (throws on malformed input)
let event = json->Message.decode(Spec.eventSchema)
// ↳ calls S.parseJsonOrThrow(eventSchema)
```

Every aggregate's `command`, `event`, and `error` types use this pattern. Every Lambda handler
round-trip (SQS → handler → EventLog) encodes and decodes through sury schemas.

### 1.2 DCB Tag Extraction (Schema Introspection)

The DCB event sourcing pattern requires tagging events with entity IDs (e.g. `customerId`,
`productId`) so that the event store can filter events by entity without deserializing payloads.
Sury supports this via custom metadata attached to individual schema fields:

```rescript
// Mark a field as a DCB tag using sury metadata
@schema
type event =
  | ItemCreated({itemId: @s.matches(DcbTag.string) string, name: string})
//                        ^^^^^^^^^^^^^^^^^^^^^^^^
// This injects DcbTag.string (= S.string->S.Metadata.set(~id=dcbTagId, true))
// at the field's schema, annotating it as a tag carrier.
```

At runtime `DcbTag.extractTags(Spec.eventSchema, event)` traverses the schema AST via
`S.Metadata.get`, finds all fields carrying the `dcbTagId` metadata, and returns
`array<{key: string, value: string}>` for storage. This is used in `DcbEventLog_Operations.res`
on every event write.

### 1.3 Schema Introspection for Field Enumeration

`ExportMeta.res` (in `reventless-interop`) uses `S.reverseConvertToJsonOrThrow` to serialise
Pulumi stack metadata and `fieldNamesOf` to enumerate which fields exist on a record type.
This is a lighter use case but relies on the same schema infrastructure.

---

## 2. How Effect Schema Works

Effect Schema (`import * as Schema from "effect/Schema"`) is the TypeScript schema library
shipped inside the main `effect` package since Effect 3.10 (October 2024). Previously it was a
separate package `@effect/schema`.

### 2.1 Core Feature Set

```typescript
// Define a schema — all manual, no code generation
const Event = Schema.Union(
  Schema.Struct({ _tag: Schema.Literal("ItemCreated"), itemId: Schema.String, name: Schema.String }),
  Schema.Struct({ _tag: Schema.Literal("ItemRenamed"), itemId: Schema.String, newName: Schema.String }),
)

// Decode (throws)
const event = Schema.decodeUnknownSync(Event)(json)

// Encode
const json = Schema.encodeSync(Event)(event)

// JSON Schema output (Draft 7 / OpenAPI 3.1)
import * as JSONSchema from "effect/JSONSchema"
const jsonSchema = JSONSchema.make(Event)
```

| Feature | Sury | Effect Schema |
|---------|------|--------------|
| Parse JSON | `S.parseJsonOrThrow(schema)` | `Schema.decodeUnknownSync(schema)` |
| Encode to JSON | `S.reverseConvertToJsonOrThrow(schema)` | `Schema.encodeSync(schema)` |
| JSON Schema output | `S.toJSONSchema(schema)` | `JSONSchema.make(schema)` |
| Custom field metadata | `S.Metadata.set(~id, value)` / `@s.matches` | `.annotations({[Symbol]: value})` |
| Schema introspection | `S.Metadata.get(~id, schema)` + AST walk | `SchemaAST.getAnnotation(Symbol)(ast)` |
| Union / variant types | Native ReScript variants via PPX | `Schema.Union` + manual `_tag` discriminant |
| Async validation | No (sync only) | Full Effect integration |
| Arbitrary test data | No | `@effect/vitest` / fast-check |
| Standard Schema v1 | Yes (v10+) | Yes |
| TypeScript | Yes (JS-first, TS supported) | Yes (TS-first) |
| ReScript | **Native — the primary target** | **No — TypeScript only** |

### 2.2 ReScript Bindings for Effect Schema

There are **no maintained ReScript bindings for Effect Schema**. Searching npm, JSR, and
GitHub produces:

- `ts-to-effect-schema` (daotl/ts-to-effect-schema) — a code generator going
  TypeScript → Effect Schema. Last published 2 years ago, 7 stars, appears abandoned.
- No package named `rescript-effect-schema` or equivalent exists.

Creating ReScript bindings for Effect Schema would require writing external bindings for
the entire `Schema`, `SchemaAST`, and `JSONSchema` modules — a non-trivial effort given the
size and complexity of the TypeScript generics involved.

### 2.3 Code Generation / PPX

Effect Schema has **no PPX and no compile-time code generation toolchain**. Every schema must
be written manually. The only generation tool is `quicktype` (JSON sample → Effect Schema),
which works in one direction only and is not integrated into the build.

Sury ships `sury-ppx`, which generates schema values from `@schema`-annotated ReScript type
declarations at compile time. This is the single biggest practical difference: the ~112 files
in this codebase that use `@schema` have zero hand-written schema definitions — all are
auto-generated by the PPX.

---

## 3. GraphQL SDL Generation — Where Both Libraries Stand

The user's question specifically asks about "generation of GraphQL schemas out of ReScript type
schemas". This section addresses the current state directly.

### 3.1 What Reventless Currently Does

The in-memory GraphQL server (`GraphQL_Server.res`) builds SDL as **hand-written string
templates**. For example:

```rescript
// QueryDbResolvers_GraphQL.res
let sdlFields = Array.concat(
  [byIdField(name)],
  indexFields->Array.map(indexField(name, _)),
)

// CommandGeneratorResolvers_GraphQL.res
let sdlFields = fields->Array.map(field => `  ${field}(id: ID, args: String): String`)
```

Sury schemas are **not involved** in this SDL generation. The GraphQL types returned from all
resolvers are opaque `String` or `JSON` scalars — there is no type-driven SDL derivation
anywhere in the codebase.

### 3.2 Effect Schema: No GraphQL Support

Effect Schema generates JSON Schema (OpenAPI 3.1, Draft 7, 2019-09, 2020-12). There is no
official `effect/GraphQL` module, no community npm package translating Effect schemas to
GraphQL SDL, and no GitHub discussion indicating this is planned.

### 3.3 Sury: No GraphQL Support Either

Sury generates JSON Schema via `S.toJSONSchema(schema)`. It has no GraphQL output mode.

### 3.4 The Path to Type-Driven GraphQL SDL (Using Sury)

Both libraries stop at JSON Schema / OpenAPI. However, **JSON Schema → GraphQL SDL is a
well-supported conversion**. The pragmatic path to derive GraphQL types from Reventless
schemas — without changing any library — is:

1. Call `S.toJSONSchema(Spec.eventSchema)` to get a JSON Schema object.
2. Run it through a JSON Schema → GraphQL SDL converter at startup.
   Community tools: `@graphql-tools/utils`'s `buildASTSchema`, or the dedicated
   `json-schema-to-graphql-types` approach.
3. Register the derived SDL in `GraphQL_Server`.

This would let QueryDb resolvers return strongly-typed results (e.g. `ProductAdded` instead of
`String`) driven by the existing sury schemas — no library change required.

A custom PPX attribute such as `@graphqlType` could additionally mark which types should be
exposed as GraphQL types, generating both the sury schema and the SDL fragment in one
annotation. This is achievable as a sury-ppx extension or as a separate PPX.

---

## 4. Feature-by-Feature Comparison Against the Current Usage

### 4.1 JSON Encode / Decode

| Aspect | Sury | Effect Schema |
|--------|------|--------------|
| API in ReScript | `S.parseJsonOrThrow(schema)`, `S.reverseConvertToJsonOrThrow(schema)` | No ReScript API (TypeScript only) |
| Performance | Claims fastest in JS ecosystem — uses JIT via `new Function`. **Not compatible with Cloudflare Workers** | No comparable benchmark; Effect runtime overhead |
| Error messages | Configurable via `@s.meta({message: ...})` | Rich structured errors via `ParseError`; configurable via `.annotations({message})` |
| Throws vs. returns | Throws by default; `parseJsonOrThrow` / `parseOrThrow` variants | Sync throws (`decodeUnknownSync`) or `Either`/`Effect` returns |

**Assessment:** Functionally equivalent for the Reventless use cases. Sury's performance edge
matters in Lambda hot paths. No advantage to switching.

### 4.2 Variant / Union Types

| Aspect | Sury | Effect Schema |
|--------|------|--------------|
| ReScript variant support | Native — PPX generates union schemas that roundtrip ReScript constructors exactly | No ReScript variants; must use `Schema.Union` with explicit `_tag` field |
| Payload-less variants | Serialize as JSON strings (known gotcha — DCB events must have payloads) | `Schema.Literal` — serialize as literal strings |
| Inline record variants | `ItemCreated({id, name})` → `{"ItemCreated": {"id": ..., "name": ...}}` via PPX | Requires `Schema.TaggedStruct("ItemCreated")({id: ..., name: ...})` manually |
| Wire format | Constructor name is the discriminant key (configurable via `@as`) | `_tag` field is always the discriminant key |

**Assessment:** Sury's PPX-native variant support is a major ergonomic advantage for ReScript.
Replacing it with Effect Schema would require every aggregate's `command`, `event`, and `error`
types to have manually maintained `TaggedStruct` definitions — and changing the JSON wire
format used to serialize events already stored in DynamoDB.

### 4.3 DCB Tag Extraction (Schema Metadata)

| Aspect | Sury | Effect Schema |
|--------|------|--------------|
| Custom metadata on fields | `S.Metadata.set(~id=dcbTagId, true)` attached at type-annotation level via `@s.matches(DcbTag.string)` | `.annotations({[dcbTagSymbol]: true})` at the TypeScript definition level |
| Runtime introspection | `DcbTag.extractTags(schema, value)` traverses AST and collects tagged fields | Would require custom `SchemaAST` traversal in TypeScript, then bound from ReScript |
| PPX support | `@s.matches(DcbTag.string)` injects metadata at any field inline | No PPX — annotation must be applied manually to each field schema |

**Assessment:** The DCB tag extraction is the most critical and most fragile integration point.
It relies on sury's metadata system and PPX injection at field level. Reproducing this in
Effect Schema would require:

1. Writing TypeScript bindings for `SchemaAST` traversal.
2. Writing a ReScript binding layer on top.
3. Re-annotating every DCB event type manually instead of using `@s.matches`.
4. Verifying that the extracted tag values match exactly — any wire format change would corrupt
   existing event stores.

### 4.4 PPX Code Generation

| Aspect | Sury | Effect Schema |
|--------|------|--------------|
| Compile-time generation | `sury-ppx`: `@schema` → `<typeName>Schema: S.t<t>` generated at compile time | **None.** All schema definitions must be written by hand. |
| Affected files | ~112 .res files — zero hand-written schema definitions | 112 files × average 3 schemas each = ~336 schema definitions to write manually |
| Type drift risk | Impossible — schema is always derived from the type | High — schema must be kept in sync with the type by hand |
| `@s.matches` injection | Inline on type annotation: `field: @s.matches(customSchema) string` | Not possible — no PPX mechanism |

**Assessment:** The PPX gap is the decisive obstacle. Every `@schema`-annotated type in the
codebase would need a hand-maintained schema definition added alongside it. This is hundreds of
definitions that would silently drift out of sync with their types the moment a field is added
or renamed.

---

## 5. Does the Replacement Make Sense?

### 5.1 No — for the following concrete reasons

**1. No ReScript bindings exist.**
Effect Schema is a TypeScript library. Using it from ReScript requires writing bindings for
the entire Schema and SchemaAST modules. This is substantial upfront work with ongoing
maintenance burden whenever `effect` updates its Schema API (which it does frequently).

**2. No PPX equivalent.**
The sury-ppx is not a convenience — it is structural. Without it, type safety between a
ReScript type declaration and its schema is unenforced at compile time. Every schema would
need to be maintained manually alongside its type.

**3. Wire format change for existing events.**
Sury serialises `ItemCreated({id, name})` as `{"ItemCreated": {"id": ..., "name": ...}}`.
Effect Schema's `TaggedStruct` serialises as `{"_tag": "ItemCreated", "id": ..., "name": ...}`.
Any migration would require a data migration of all events stored in DynamoDB — a high-risk,
high-cost operation.

**4. DCB tag extraction would need a full reimplementation.**
The current `DcbTag.extractTags` function is ~50 lines of sury-specific AST traversal. It is
tested, production-ready, and has known behaviour. Replacing it with an Effect Schema
equivalent would mean writing ReScript bindings for `SchemaAST`, implementing equivalent
traversal logic, and verifying correctness against existing stored events.

**5. No GraphQL generation in either library.**
The premise that Effect Schema generates GraphQL SDL from type schemas is incorrect — it does
not. Nor does sury. Both stop at JSON Schema / OpenAPI output. The path to type-driven GraphQL
SDL in Reventless runs through sury's existing JSON Schema output, not through a library swap.

**6. Sury is the ReScript-native choice; Effect Schema is TypeScript-native.**
Sury is maintained by Dmitry Zakharov specifically for the ReScript ecosystem. It aligns with
ReScript's type system, PPX infrastructure, and compilation model. Effect Schema is designed
for TypeScript and assumes TypeScript's structural types, decorators, and module augmentation
— none of which map cleanly to ReScript.

### 5.2 Possible upside if constraints were removed

The one genuine advantage Effect Schema would offer — if the ReScript binding problem were
solved — is deeper integration with the Effect runtime. Currently, sury schemas are used
purely for synchronous serialisation. If schemas needed to describe async transformations or
carry Effect `'r` requirements (e.g. "validating this command requires a database lookup"),
sury would hit a ceiling because it is synchronous-only. Effect Schema can express async
validation as a full `Effect.t` pipeline.

This is not a current need in Reventless. All serialisation is synchronous. The need for
async validation would have to arise first before this advantage has practical weight.

---

## 6. What Should Be Done Instead

### 6.1 Type-driven GraphQL SDL generation (on top of sury)

This is the feature the user's question points toward. The path:

1. **Add a `@graphql` sury-ppx attribute** (or a companion PPX) that marks types as
   GraphQL-exposed. The PPX generates both the sury schema and an SDL fragment.

2. **Use `S.toJSONSchema` + a converter** at Platform startup to derive SDL from sury schemas
   that are already defined. Tools:
   - Write a `SchemaToGraphQL.res` module that maps sury JSON Schema output to SDL strings.
   - Replace the hand-written SDL templates in `CommandGeneratorResolvers_GraphQL.res` and
     `QueryDbResolvers_GraphQL.res` with schema-derived fragments.

3. **Short-term pragmatic version:** For each QueryDb that exposes read model state, call
   `S.toJSONSchema(Spec.stateSchema)` and map JSON Schema object properties to GraphQL fields
   at server startup. This gives strongly-typed resolvers without any PPX changes.

### 6.2 Keep sury; incrementally improve schema ergonomics

Sury v11 (currently in alpha) ships additional PPX attributes and improved error messages.
Staying on the upgrade path is low-risk. The current `@s.matches`, `@s.meta`, `@s.null` etc.
attributes already cover all Reventless use cases.

### 6.3 Evaluate rescript-schema / sury JSON Schema output for OpenAPI docs

`S.toJSONSchema` produces valid OpenAPI 3.1 output. This can feed an OpenAPI spec generator
for Reventless's HTTP / GraphQL API surface with no additional library. Worth documenting as a
tooling option when the framework's API exposure story matures.

---

## 7. Summary

| Question | Answer |
|----------|--------|
| Does Effect Schema have ReScript bindings? | No |
| Does Effect Schema have a PPX? | No |
| Does Effect Schema generate GraphQL SDL? | No |
| Does sury generate GraphQL SDL? | No |
| Can sury's JSON Schema output drive GraphQL SDL derivation? | Yes — via a converter layer |
| Is replacing sury with Effect Schema feasible? | Theoretically yes; practically no due to PPX gap, wire format change, and no ReScript support |
| Does the replacement make sense? | No |
| What is the right path to type-driven GraphQL SDL? | Build a `S.toJSONSchema` → SDL converter on top of the existing sury integration |
| Is there any scenario where Effect Schema would be worth adopting? | Only if Reventless moved to TypeScript, or if async schema validation became a core requirement |
