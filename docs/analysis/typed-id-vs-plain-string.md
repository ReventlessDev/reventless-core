# Typed Id Module vs Plain String IDs

**Created:** 2026-03-16

---

## Context

Every component spec in Reventless (Aggregate, ReadModel, StateChangeSlice, etc.) requires a
`module Id: Id.T` that defines the identity type for that component's entities. The framework
provides two implementations:

- **`Id.String`** — sealed abstract type (production use)
- **`Id.StringPure`** — transparent `type t = string` (test use)

Both satisfy the `Id.T` module type:

```rescript
module type T = {
  @schema
  type t
  type input
  let make: input => t
  let makeFromString: string => t
  let toString: t => string
  let cmp: (t, t) => Ordering.t
}
```

This analysis evaluates whether keeping the abstract `Id.T` module is worth the complexity
compared to using plain `string` everywhere.

---

## Option A: Keep Typed Id Modules (Status Quo)

### How It Works Today

Component specs declare `module Id = Id.String`. Message envelopes are generic over the Id type:

```rescript
type event'<'id, 'event> = { id: 'id, meta: meta, event: 'event }
type command'<'id, 'command> = { id: 'id, meta: meta, command: 'command }
```

At serialization boundaries (adapters, Lambda handlers), the framework converts between
`Spec.Id.t` and `string` using `Spec.Id.toString` / `Spec.Id.makeFromString`.

### Advantages

**1. Cross-aggregate ID confusion is caught at compile time**

With abstract IDs, each aggregate's `Id.t` is a distinct type. Passing a `CartSpec.Id.t` where
an `OrderSpec.Id.t` is expected is a type error. With plain strings, this class of bug is
invisible to the compiler and surfaces only at runtime (or not at all — silently loading the
wrong entity).

```rescript
// With Id.String — compile error: CartSpec.Id.t != OrderSpec.Id.t
let processOrder = (orderId: OrderSpec.Id.t) => ...
processOrder(cartId) // TYPE ERROR

// With plain string — compiles fine, fails silently
let processOrder = (orderId: string) => ...
processOrder(cartId) // no error, wrong entity loaded
```

**2. Self-documenting function signatures**

```rescript
// Typed: clear what kind of ID this is
let load: Spec.Id.t => promise<option<Spec.state>>

// String: ambiguous — aggregate ID? correlation ID? user ID?
let load: string => promise<option<state>>
```

Every function that accepts or returns an Id makes explicit which domain entity it refers to.
This is particularly valuable in cross-component code like CommandGenerator, EventMapper, and
Projection where multiple Id types coexist.

**3. Intentional conversion forces awareness of boundaries**

The `toString` / `makeFromString` calls are explicit markers of where the typed domain leaves
off and the untyped infrastructure begins. These conversion points serve as natural
documentation of the system's serialization boundaries. Developers cannot accidentally bypass
serialization — they must consciously convert.

**4. Extensibility for non-string IDs**

The `Id.T` module type supports any backing type via `type input` and `type t`. If a future
use case requires composite IDs (e.g., `{tenantId, entityId}`), UUID types, or integer IDs,
the abstraction already supports it without changing any consumer code. The `cmp` function
enables sorted data structures and range queries regardless of the underlying representation.

**5. Schema integration via `@schema`**

The `@schema type t` annotation means sury automatically generates serialization schemas for
IDs. Custom Id implementations can define their own schema (e.g., UUID validation, format
constraints) and the entire serialization chain picks it up automatically.

### Costs

- **Boilerplate in specs:** Every spec needs `module Id = Id.String` (one line).
- **Conversion at boundaries:** `toString` / `makeFromString` calls in adapters and callbacks.
  These already exist in ~15 locations across the codebase.
- **Test friction:** Tests must either use `Id.StringPure` or call `makeFromString` for
  literal IDs. This is why `Id.StringPure` exists — it eliminates friction in test fixtures.
- **Learning curve:** New developers must understand the Id module pattern before they can
  write specs. The pattern is consistent across all components, so it is learned once.

---

## Option B: Replace With Plain Strings

### What Would Change

1. Remove `module Id: Id.T` from all component specs.
2. Change message envelope types from `event'<'id, 'event>` to `event'<string, 'event>` or
   remove the `'id` type parameter entirely.
3. Remove all `toString` / `makeFromString` conversion calls from adapters and callbacks.
4. Delete `Id.res` / `Id.resi` (or reduce to just the `cmp` function).

### Advantages

**1. Less boilerplate**

No `module Id = Id.String` in specs. No conversion calls at serialization boundaries.
Approximately 15-20 conversion call sites would be removed.

**2. Simpler message types**

```rescript
// Before: two type parameters
type event'<'id, 'event> = { id: 'id, meta: meta, event: 'event }

// After: one type parameter
type event'<'event> = { id: string, meta: meta, event: 'event }
```

Fewer generic type parameters means simpler type signatures throughout the framework,
especially in callback and builder modules where the `'id` parameter must be threaded through.

**3. No test/production divergence**

No need for `Id.StringPure` vs `Id.String` distinction. Test code and production code use
the same type. Test fixtures can use string literals directly without any wrapper.

**4. Smaller API surface**

New developers see `id: string` and immediately understand it. No module type, no abstract
type, no conversion functions to learn.

### Consequences

**1. Loss of compile-time cross-aggregate safety**

This is the most significant consequence. Any `string` can be passed as any entity ID.
Refactoring that changes which aggregate an ID belongs to will not produce compile errors.
Bugs where the wrong ID is used to load/save state become possible and invisible to the
compiler.

In a CQRS/event-sourced system, this class of bug is particularly dangerous because:
- A wrong aggregate ID silently loads a different entity's event stream
- Commands dispatched with a wrong ID mutate the wrong entity
- The error may not surface until much later (eventual consistency delays detection)

**2. Ambiguous function signatures**

Functions like `load(string) => promise<option<state>>` no longer communicate which kind of
ID they expect. In code that handles multiple entity types (CommandGenerator callbacks,
Projection mappings, cross-plugin extension points), this ambiguity compounds.

Developers must rely on naming conventions (`orderId`, `cartId`) rather than types.
Naming conventions are not enforced by the compiler.

**3. Lost extensibility for non-string IDs**

If a use case requires composite IDs, UUID types, or integer IDs in the future, the change
would require re-introducing the abstraction or creating ad-hoc wrappers. This is a one-way
door — removing the abstraction is easy, but re-introducing it later requires touching every
spec, builder, adapter, and callback.

**4. Serialization boundary markers disappear**

The explicit `toString` / `makeFromString` calls currently mark exactly where the domain
meets infrastructure. Removing them makes these boundaries implicit. While the calls are
admittedly mechanical, they serve as guardrails during code review — a reviewer can verify
that ID conversion happens at the right point.

**5. DCB tag interaction**

In the DCB approach, entity ID fields in events/commands use `@s.matches(DcbTag.string)` for
content-based routing. These fields are already plain `string` annotated with schema
attributes. The DCB approach does not use `Id.t` for tag fields — so removing `Id.T` would
not simplify DCB specs. The two mechanisms are orthogonal.

---

## Comparison Matrix

| Criterion                        | Typed Id (Status Quo)          | Plain String                  |
|----------------------------------|--------------------------------|-------------------------------|
| Cross-aggregate type safety      | Compile-time error             | Silent runtime bug            |
| Spec boilerplate                 | 1 line per spec                | None                          |
| Conversion boilerplate           | ~15 call sites                 | None                          |
| Function signature clarity       | Self-documenting               | Relies on naming conventions  |
| Non-string ID extensibility      | Built-in                       | Would require re-introduction |
| Test ergonomics                  | Requires StringPure or wrapper | Direct string literals        |
| Learning curve                   | Module type pattern (one-time) | None                          |
| Serialization boundary markers   | Explicit                       | Implicit                      |
| Message type parameter count     | 2 (`'id`, `'event`)           | 1 (`'event`)                  |
| DCB tag handling                 | Orthogonal (no impact)         | Orthogonal (no impact)        |

---

## Current Inconsistencies in Id Handling

Regardless of which option is chosen, the current codebase has inconsistencies in how IDs are
converted that could be cleaned up.

### 1. Two parallel serialization mechanisms for the same value

The framework converts IDs to strings via two different paths:

- **Schema-based:** `Spec.Id.schema` passed to `Message.encodeEvent'` / `Message.decodeEvent'`
  (sury `S.t<Id.t>` schema — structured JSON encode/decode)
- **Manual:** `Spec.Id.toString` / `Spec.Id.makeFromString` (direct string conversion)

Both produce the same result for `Id.String`, but they are used inconsistently across
components:

| Component | JSON envelope encoding | Storage adapter calls | Log messages |
|-----------|----------------------|----------------------|--------------|
| EventLog_Operations | `Spec.Id.schema` (line 41) | `Spec.Id.toString` (lines 78, 135, 142, 154) | `Spec.Id.toString` |
| EventTopic_Operations | `Spec.Id.schema` via `encodeEvent'` (line 10) | `Spec.Id.toString` (line 15) | — |
| QueryDb_Operations | `ReadModelSpec.Id.schema` in state JSON (lines 43, 55) | `ReadModelSpec.Id.toString` for storage keys (lines 20, 29, 45) | `ReadModelSpec.Id.toString` |
| Aggregate_Callback | — | — | `Spec.Id.toString` |
| CommandTopic (via Message) | `~idToString` function parameter | — | — |

The distinction is defensible — schema encoding is for structured JSON objects while `toString`
is for flat string keys — but nowhere is this rule documented or enforced. A reader seeing
both patterns in the same file (e.g., `QueryDb_Operations.save` at lines 43-45) must infer
when to use which.

**Possible improvement:** Document the convention explicitly: `Spec.Id.schema` is for embedding
IDs in JSON documents (event store records, query DB state), `Spec.Id.toString` is for
infrastructure keys (storage partition keys, dict grouping, log strings).

### 2. `commandJsonOfCommand'` uses `~idToString` while `encodeEvent'` uses `idSchema`

`Message.res` defines two symmetric envelope-encoding functions with different ID conversion
strategies:

```rescript
// Events: schema-based (line 37)
let encodeEvent' = (event', idSchema, eventSchema) =>
  event'->S.reverseConvertToJsonOrThrow(toEventSchema'(idSchema, eventSchema))

// Commands: function-based (line 212)
let commandJsonOfCommand' = (~idToString, ~commandSchema, cmd) => {
  id: cmd.id->idToString,
  meta: cmd.meta,
  commandJson: cmd.command->encode(commandSchema),
}
```

Events are encoded by passing the full `Spec.Id.schema` to sury, which produces a structurally
validated JSON object. Commands are encoded by passing a `~idToString` function, producing a
`commandJson` record with `id: string`.

This asymmetry exists because `commandJson` is a ReScript record type (with `id: string`
already baked in), while `event'` encoding produces a raw `JSON.t`. But it means the two
message types follow different conversion patterns for the same conceptual operation.

**Possible improvement:** Align the two paths. Either change `commandJsonOfCommand'` to also
accept `idSchema` and use sury for the full envelope, or acknowledge the asymmetry as
intentional (commands go through `commandJson` which is already string-typed by design).

### 3. Extension_Operations hardcodes `Id.StringPure.schema`

In `Extension_Operations.res` (line 148), incoming cross-plugin events are decoded with a
hardcoded `Reventless.Id.StringPure.schema` instead of the mapping spec's ID schema:

```rescript
switch eventJson'->Message.decodeEvent'(
  Reventless.Id.StringPure.schema,  // hardcoded, not from spec
  MappingSpec.eventSchema,
)
```

This works because cross-plugin events arrive as serialized JSON where the ID is already a
plain string. But it silently bypasses the typed ID system — the decoded `event'.id` is
`string`, not `MappingSpec.Id.t`.

This is consistent with how the rest of Extension_Operations works (line 37 types events as
`Message.event'<string, MappingSpec.event>` — the `'id` parameter is explicitly `string`).
The extension boundary is intentionally untyped because events cross plugin boundaries where
the source aggregate's ID type is not available.

**Possible improvement:** Make this intentional untyping more visible. The `ExtensionMapping`
spec could explicitly declare `type id = string` to document that extension mappings always
work with string IDs, rather than having the hardcoded `StringPure.schema` deep in the
operations module.

---

## Recommendation

**Keep the typed Id module.** The compile-time safety against cross-aggregate ID confusion is
the decisive factor. In an event-sourced system, accidentally loading or mutating the wrong
entity's stream is a high-severity bug that is difficult to detect and can cause data
corruption. The cost of prevention (one line per spec + ~15 conversion calls) is low relative
to the risk.

The existing `Id.StringPure` escape hatch already solves the test ergonomics concern. The
extensibility for non-string IDs is a valuable option that costs nothing to maintain but would
be expensive to reintroduce.
