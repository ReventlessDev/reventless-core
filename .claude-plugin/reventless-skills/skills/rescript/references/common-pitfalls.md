# ReScript Common Pitfalls

## Compiler Warnings

### Warning 44: Open Shadows

```rescript
// WRONG — @warning on open does NOT work in ReScript
@warning("-44") open SomeModule

// CORRECT — file-level attribute at the top
@@warning("-44")
```

**Root cause:** `open` shadows names from enclosing scope. Common with `open ReventlessCore` inside reventless-core tests (redundant — remove the open entirely).

### Warning 32: Unused Value in Sealed Module

When a module is constrained with `: ModuleType`, values not in `ModuleType` are unused:

```rescript
module M: T = {
  let used = 42      // in T — OK
  let notInT = "hi"  // NOT in T — warning 32
}
```

**Fix:** Remove values not in the module type, or remove the constraint.

### Warning 23: Redundant Spread

```rescript
// WRONG — state has only one field, spread is redundant
let newState = {...state, count: 5}

// CORRECT
let newState = {count: 5}
```

If the function argument becomes unused after removing the spread, prefix it with `_`:

```rescript
let evolve = (_state, event) => ...
```

## Type System Gotchas

### Result.toOption Does Not Exist

`RescriptCore` does not have `Result.toOption`. Use inline switch:

```rescript
// WRONG
let opt = result->Result.toOption

// CORRECT
let opt = switch result {
| Ok(v) => Some(v)
| Error(_) => None
}
```

### Optional Record Fields

Optional fields use `?` syntax. In literals, provide the value directly (not wrapped in `Some`):

```rescript
type config = {name: string, debug?: bool}

// CORRECT
let c = {name: "test", debug: true}

// WRONG
let c = {name: "test", debug: Some(true)}
```

### Record Pun with Single Field

`{handlerRef}` is a **block** (expression wrapped in braces), not a record literal:

```rescript
// WRONG — parsed as block, not record
let r = {handlerRef}

// CORRECT — explicit field
let r = {handlerRef: handlerRef}
```

### Array.getUnsafe Chaining

ReScript parses `arr->Array.getUnsafe(0).field` incorrectly:

```rescript
// WRONG — parsed incorrectly
let name = items->Array.getUnsafe(0).name

// CORRECT — use intermediate variable
let first = items->Array.getUnsafe(0)
let name = first.name
```

### Type Annotations for Record Fields in Switch

When pattern matching returns a record, annotate to disambiguate:

```rescript
switch opt {
| Some(rec: RecordType) => rec.field
| None => fallback
}
```

### Return Type Annotations for Abstract Types

Required when returning values with abstract types:

```rescript
let makeId = (s: string): Id.String.t => {
  Id.String.makeFromString(s)
}
```

## Deprecated APIs

| Deprecated | Replacement |
|-----------|-------------|
| `Js.Exn.asJsExn` | `JsExn.fromException` |
| `Js.Exn.message` | `JsExn.message` |
| `Js.log` | `Console.log` |
| `Js.Promise.resolve` | `Promise.resolve` |
| `Js.Dict` | `Dict` |
| `Js.Array2` | `Array` |
| `Js.String2` | `String` |

## sury-ppx Gotchas

### @s.matches Placement

Annotation must go on the **type expression**, not the field name:

```rescript
// CORRECT
productId: @s.matches(DcbTag.string) string

// WRONG — silently ignored
@s.matches(DcbTag.string) productId: string
```

### Schema Name for `type t`

The generated schema for `type t` is `schema`, NOT `tSchema`:

```rescript
@schema type t = {name: string}
// Generated: let schema: S.t<t>  (not tSchema)
```

## Build and Test Gotchas

### Stale Build Cache

After reorganizing source files (moving, renaming):

```bash
npx rescript clean && npm run build
```

### Component.js Overwrite

`reventless-spec/src/components/Component.js` is a **hand-written** file. Running `rescript clean && rescript build` inside `packages/reventless-spec/` overwrites it with a broken circular-require version. Always restore from git if this happens.

### ESM Output

Root `rescript.json` controls output format (`"module": "esmodule"`, `"suffix": ".res.mjs"`). Per-package `rescript.json` files have no `package-specs` — they inherit from root when built from root.

### testPromise Is Broken

`@glennsl/rescript-jest`'s `testPromise` does NOT await the returned Promise — tests run concurrently, causing race conditions on shared mutable state.

**Fix:** Use native Jest binding:

```rescript
@val external jestTest: (string, unit => promise<unit>) => unit = "test"

jestTest("my async test", async () => {
  let result = await someAsyncOp()
  expect(result)->toBe(expected)
})
```

### jest Object in ESM Mode

The `jest` object is NOT injected as a bare global in ESM mode:

```rescript
@module("@jest/globals") external jest: jestObj = "jest"
```

Place `useFakeTimers` in `beforeAll`, not at module top level.
