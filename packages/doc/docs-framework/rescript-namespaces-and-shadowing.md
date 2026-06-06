# ReScript Namespaces and Module Shadowing

## How the flat module namespace works

ReScript (like OCaml) compiles every `.res` file to a module interface (`.cmi`) and places it in a flat global namespace. All modules visible to the compiler — from the current package and its dependencies — coexist in this namespace. Without any scoping mechanism, a `CommandTopic.res` from one package would collide with a `CommandTopic.res` from another.

## The `"namespace"` setting

The `"namespace"` key in `rescript.json` is the scoping mechanism:

| Setting | Effect |
|---------|--------|
| `"namespace": "Reventless"` | Each file `Foo.res` is internally renamed to `Reventless__Foo.cmi`. A wrapper `Reventless.cmi` re-exports them as submodules (`module Foo = Reventless__Foo`). The bare name `Foo` is **not** in the global namespace — only `Reventless.Foo`. |
| `"namespace": false` (or omitted) | Files keep their plain names (`Foo.cmi`). They land directly in the flat global namespace of every consuming package, accessible unqualified as `Foo`. |

## Why some modules are available unqualified

There are two sources of unqualified module access in a ReScript package:

### 1. Same-package modules

All `.res` files within a single package share a flat namespace with each other. If `reventless-local` lists both `src/` and `tests/` in its `"sources"`, every file in both directories sees every other file unqualified — regardless of subdirectory. This is why `TestRunner`, `LocalBus`, `AsyncTest`, `DcbEventLog_Builder` etc. are all accessible without a prefix inside the test files.

### 2. Dependencies with `"namespace": false`

Dependency packages that omit a namespace expose their modules globally. The key example in this codebase:

```json
// node_modules/@glennsl/rescript-jest/rescript.json
{
  "namespace": false
}
```

Because `@glennsl/rescript-jest` has no namespace, its modules (`AsyncTest`, `Jest`) are placed directly in the global flat namespace of every package that depends on it. That is why `open AsyncTest` works without any prefix in test files.

Similarly, `sury` (the schema library) likely has no namespace, which is why `S` is accessible unqualified.

By contrast, `reventless-spec` (`"namespace": "Reventless"`) and `reventless` (`"namespace": "Reventless"`) namespace all their modules — so you must write `Reventless.CommandTopic` and `ReventlessCoreCommandTopic`, not bare `CommandTopic`.

## Warning 44: open statement shadows an identifier

ReScript warning 44 fires when an `open` statement introduces a name that already exists in scope:

```
Warning 44: this open statement shadows the module identifier CommandTopic
```

This warning appeared in `DcbE2EFixtures.res` because the file contained:

```rescript
open Reventless  // ← warning 44: shadows CommandTopic
```

Before the `open`, `CommandTopic` referred to `ReventlessCoreCommandTopic` (the implementation module, which has `getHandlers`). After the `open`, `CommandTopic` was re-bound to `Reventless.CommandTopic` (the type-only specification, which does NOT have `getHandlers`). Any code that called `CommandTopic.getHandlers` would then fail at the type-check stage.

### Fix

Remove the broad `open` and qualify all uses explicitly:

```rescript
// Before (problematic):
open Reventless
...
let handlers = CommandTopic.getHandlers(typeName)  // resolves to Reventless.CommandTopic — no getHandlers!

// After (correct):
let handlers = ReventlessCoreCommandTopic.getHandlers(typeName)
...
let testMeta: Reventless.Message.meta = { ... }
```

## General advice

- **Prefer `open` at a small scope** (inside a `let` block or function) rather than at module top level. This limits the shadowing risk.
- **Avoid `open`ing two packages that share module names** (e.g., `open Reventless` and then relying on `ReventlessCoreCommandTopic` unqualified).
- **Warning 44 is a signal, not noise** — it usually means a wrong module will be selected after the open. Treat it as an error (`+44` in `rescript.json` `"warnings": { "error": "+44" }`).
- **Use `-44` only when the shadowing is intentional** and you have verified correctness. The `reventless-local` package uses `"-44"` to suppress it as a non-error, relying on compiler warnings being visible in the build output.
