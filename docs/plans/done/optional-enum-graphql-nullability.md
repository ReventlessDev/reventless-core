# Plan: preserve nullability for optional enum fields in generated GraphQL

**Date:** 2026-07-26
**Status:** Implemented — `SchemaType.res` fix + test landed; full root build clean (zero
warnings), `reventless-local` (512) and `reventless-core` (532) suites green. Remaining:
publish core + bump the graphql-server pin + redeploy the API Lambda (Rollout steps 2–3).
**Repos:** `reventless-core` only.

> **Note (confirmed in-the-wild instance):** the admin `Platform_Plugins.kind` field is
> already `option<Reventless.Plugin.pluginKind>`
> (`reventless/core/src/plugin/lifecycle/PluginsReadModelSpec.res:55`), with a source comment
> describing this exact "one null row collapses the whole list" failure. Before the fix it
> rendered `kind: Platform_PluginKind!`; the `GraphQL_SchemaInspectorTest` assertion pinning
> that `!` was updated to require the nullable form (`kind: Platform_PluginKind`, no `!`).

## Why

The sury → GraphQL type deriver drops the optionality of a field whose type is an
**optional multi-variant enum**. Such a field is emitted as a **non-null** GraphQL enum
(`SomeEnum!`), so any row that resolves the field to `null` violates the non-null constraint.
Per the GraphQL spec a `null` in a non-null position propagates upward until it reaches a
nullable parent — in a list connection it bubbles all the way to `data: null`, taking the
**entire** response down over a single row:

> Cannot return null for non-nullable type: '<ParentType>Source' within parent '<ParentType>'

A consumer that models an attribution/classification field as an optional variant type —

```rescript
@schema
type source =
  | @as("tagged") Tagged
  | @as("ancestry") Ancestry
  | @as("substrate") Substrate
  | @as("unattributed") Unattributed

// ... field on the record:
@hidden source?: source
```

— intends the field to be nullable (the `?`), and legacy/older rows that predate the column
legitimately hold no value. The generator is meant to honour that, and does so for scalars and
objects, but not for enums.

## Root cause

`SchemaType.fromSury` (`reventless/core/src/components/Api/SchemaType.res:78-109`) handles a
sury `Union({anyOf})`. For an **optional** field, sury emits an `anyOf` of the concrete
variants **plus** a `Null`/`Undefined` member. The function filters the null members out:

```rescript
| Union({anyOf}) =>
  let nonNullVariants = anyOf->Array.filter(v =>
    switch v {
    | Null(_) | Undefined(_) => false
    | _ => true
    }
  )
  if nonNullVariants->Array.length == 1 {
    Nullable(fromSury(~parentName, ~fieldName, nonNullVariants->Array.getUnsafe(0)))
  } else {
    let constValues = /* the string literals */ ...
    if constValues->Array.length == nonNullVariants->Array.length && constValues->Array.length > 0 {
      let enumName = parentName ++ /* capitalised fieldName */ ...
      Enum(enumName, constValues)          // ← nullability lost here
    } else {
      Unknown
    }
  }
```

- The `nonNullVariants->Array.length == 1` branch (line 85) re-introduces nullability, so an
  optional **scalar** or **object** (`S.option(X)` → `anyOf = [X, Undefined]`, one non-null
  member) correctly becomes `Nullable(...)`.
- An optional **enum** has ≥2 non-null members (its literals), so control falls through to the
  enum branch (lines 94-105), which returns a **bare** `Enum(name, values)`. The fact that
  `anyOf` contained a null member is discarded.

Downstream, `GraphQL_FragmentGenerator.fromSchemaType`
(`reventless/core/src/components/Api/GraphQL_FragmentGenerator.res:32-66`) renders object
fields with `~required=true` (line 80). `Nullable(inner)` recurses with `~required=false`
(line 47, dropping the `!`); a bare `Enum` renders `${name}${bang}` = `Name!`. So the missing
`Nullable` wrapper is exactly what produces the erroneous non-null enum in the SDL.

A **required** (non-optional) variant field is unaffected: its sury schema is
`S.union([literals])` with no null member, so `nonNullVariants == anyOf`, it stays a bare
`Enum`, and correctly renders `Name!` — this is the existing, desired behaviour for
`Platform_PluginKind` and friends. The fix must preserve that.

## Change

Detect the presence of a `Null`/`Undefined` member in `anyOf` and re-apply it to the enum
branch, mirroring what the single-variant branch already does. In
`SchemaType.res:78-109`:

```rescript
| Union({anyOf}) =>
  let nonNullVariants = anyOf->Array.filter(v =>
    switch v {
    | Null(_) | Undefined(_) => false
    | _ => true
    }
  )
  let isOptional = nonNullVariants->Array.length < anyOf->Array.length
  if nonNullVariants->Array.length == 1 {
    Nullable(fromSury(~parentName, ~fieldName, nonNullVariants->Array.getUnsafe(0)))
  } else {
    let constValues = nonNullVariants->Array.filterMap(v =>
      switch v {
      | String({const: ?Some(c)}) => Some(c)
      | _ => None
      }
    )
    if constValues->Array.length == nonNullVariants->Array.length && constValues->Array.length > 0 {
      let enumName =
        parentName ++
        fieldName->String.charAt(0)->String.toUpperCase ++
        fieldName->String.slice(~start=1, ~end=fieldName->String.length)
      let enum = Enum(enumName, constValues)
      isOptional ? Nullable(enum) : enum
    } else {
      Unknown
    }
  }
```

Scope notes:

- Only the enum branch changes behaviour. The single-variant branch is untouched (it already
  wraps in `Nullable`).
- A required variant type (no null member) has `isOptional == false` → still a bare `Enum`
  → still renders `Name!`.
- No change to the `schemaType` variant set, to `GraphQL_FragmentGenerator`, or to any consumer
  of the generated SDL — a nullable enum was always renderable (`Nullable(Enum(...))`), it just
  was never produced for this shape.

## Tests

`reventless/local/tests/adapter/GraphQL_SchemaInspectorTest.res` already asserts the SDL for
generated fragments (e.g. `kind: Platform_PluginKind!` at ~line 910). Add a sibling assertion
using a fixture fragment that carries **both**:

- a **required** variant field → asserts `field: SomeEnum!` (guards the existing behaviour), and
- an **optional** variant field (`foo?: variantType`) → asserts the SDL contains `field: SomeEnum`
  and does **not** contain `field: SomeEnum!`.

This pins the exact regression: optional enum ⇒ nullable in SDL.

## Acceptance

- An optional multi-variant enum field is emitted as a **nullable** GraphQL enum (`SomeEnum`,
  no `!`); a row resolving that field to `null` no longer collapses the whole response.
- A required variant field is still emitted as `SomeEnum!` (unchanged).
- Optional scalar/object fields are unchanged (still `Nullable`).
- `GraphQL_SchemaInspectorTest` covers both the required and optional enum cases and passes.

## Rollout

1. Land the `SchemaType.res` fix + test in core; full root build + core test suite green.
2. Publish core; bump the graphql-server override pin to match (see the standing pin discipline).
3. Consumers that regenerate their API schema from an updated core pick up the nullable enum on
   their next build/deploy — the running API Lambda must be **redeployed** for the corrected SDL
   to take effect (a schema-generation change is inert until the schema is re-pushed).
