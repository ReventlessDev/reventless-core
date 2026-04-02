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

**Always use `field?: T` instead of `field: option<T>` in records.** This is the idiomatic ReScript v12 convention.

```rescript
// CORRECT — optional field syntax
type state = {
  name?: string,
  region?: string,
  removed: bool,
}

// WRONG — option<T> field
type state = {
  name: option<string>,
  region: option<string>,
  removed: bool,
}
```

**Reading** optional fields still returns `option<T>` — pattern matching and `Option.*` work unchanged:

```rescript
switch state.name {
| None => ...
| Some(n) => ...
}
```

**Writing** in a literal: provide the value directly, never wrap in `Some`:

```rescript
// CORRECT
let s = {name: "Alice", removed: false}

// WRONG
let s = {name: Some("Alice"), removed: false}
```

**Spread update**: same — value directly, not `Some`:

```rescript
// CORRECT
{...state, name: newName}

// WRONG
{...state, name: Some(newName)}
```

**Passing an `option<T>` to an optional field** (threading through from another optional field): use `field: ?optionValue`:

```rescript
// stateType is option<string> from another optional field
SyncComponent({..., stateType: ?stateType, ...})
```

**`initialState` with optional fields**: omit all optional fields — they default to `None`:

```rescript
// CORRECT — only required fields needed
let initialState = {removed: false}

// WRONG — redundant
let initialState = {name: None, region: None, removed: false}
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

### `ref` Around Mutable Collections

`Array` and `Dict` are mutable in ReScript — `push`, `set`, `splice` mutate in place. Don't use `ref` just because the collection is mutable — use it only if you need to replace the entire collection.

```rescript
// WRONG — ref used only for push, not for replacement
let items: ref<array<string>> = ref([])
items.contents->Array.push("a")
let first = items.contents->Array.getUnsafe(0)

// CORRECT — plain array when you never reassign
let items = []
items->Array.push("a")
let first = items->Array.getUnsafe(0)
```

`ref` **is** justified when you need to swap the collection entirely (e.g. clearing an accumulator):

```rescript
// OK — ref used for identity-replacement
let pending = ref([])
pending.contents->Array.push(info)
// ... later, clear by replacing with a new empty array
pending := []
```

Same applies to `Dict`:

```rescript
// WRONG — ref used only for Dict.set
let cache: ref<dict<int>> = ref(Dict.make())
cache.contents->Dict.set("k", 1)

// CORRECT — plain dict
let cache = Dict.make()
cache->Dict.set("k", 1)
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

## Obj.magic

**Never use `Obj.magic`.** It bypasses the type system entirely and produces unsound code.

**Common temptation — passing a typed value as `JSON.t`:**

```rescript
// WRONG
receive({
  "TAG": "ImportPlatform",
  "platformName": name,
}->Obj.magic)
```

**Correct — encode using the sury schema:**

```rescript
// CORRECT
receive(
  ImportPlatform({platformName: name, ...})
    ->S.reverseConvertToJsonOrThrow(externalInputSchema)
)
```

**Common temptation — coercing between incompatible dict types:**

```rescript
// WRONG
let resolvers = dict->Obj.magic

// CORRECT — use a typed external identity cast
external asResolverDict: dict<resolverFn> => dict<OtherModule.resolverFn> = "%identity"
let resolvers = dict->asResolverDict
```

`%identity` externals are structurally sound (same JS representation, different ReScript types) and self-documenting. `Obj.magic` is not.

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
