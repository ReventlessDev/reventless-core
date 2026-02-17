# Nominal Record Types in Functors & Existential Type Unification

## Problem

When multiple functor applications produce record types with identical structure, the ReScript compiler treats them as **different nominal types** — even if the field names and types are structurally identical. This causes type mismatches when passing values between modules that use independently-created functor instances.

### Concrete example

`DcbEventLog.T` defined an `operations` record type inside the module type:

```rescript
module type T = {
  module Spec: Spec
  type operations = {
    read: read<Spec.event>,
    append: append<Spec.event>,
  }
  type component = component<operations>
  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component
}
```

`CommandHandler.T` carried a nested `module DcbEventLog: DcbEventLog.T` and used `DcbEventLog.component` in its `make` signature:

```rescript
module type T = {
  module Spec: Spec
  module DcbEventLog: DcbEventLog.T with module Spec = Spec.DcbEventLogSpec
  let make: (~dcbEventLog: DcbEventLog.component, ~opts: ...) => component
}
```

In `Plugin_Builder`, a DcbEventLog was created via `DcbEventLog_Builder.Make(...)` and passed to each CommandHandler's `make`. The compiler rejected this because:

1. **Nominal record mismatch**: The `operations` record type from the Plugin's DcbEventLog functor application was a *different nominal type* than the `operations` from each CommandHandler's nested DcbEventLog — even though both had `{read: read<event>, append: append<event>}`.

2. **Existential type mismatch**: Even if the record types were unified, the event type parameter differed. `DcbSpec.event` (from the Plugin's unpacked `module(Plugin.DcbSpec)`) and `CommandHandler.Spec.DcbEventLogSpec.event` (from the unpacked `module(CommandHandler.T)`) are independent existential types. The compiler cannot prove they are equal.

### Compiler error

```
This has type:
  DcbEventLog.component (defined as Component.t<..., DcbEventLog.operations>)
But expecting:
  CommandHandler.DcbEventLog.component (defined as Component.t<..., CommandHandler.DcbEventLog.operations>)

The incompatible parts:
  DcbEventLog.operations (defined as DcbEventLog_Builder.Make(A)(B)(C).operations)
  vs CommandHandler.DcbEventLog.operations
```

## Root Cause Analysis

Two independent issues compound:

### 1. Record types in ReScript are nominal

Two record types `{read: ..., append: ...}` defined in different modules are **never equal**, even if structurally identical. When `type operations = {read: ..., append: ...}` lives inside a `module type T`, each functor application of `Make(...): T` creates a fresh nominal type.

### 2. Existential types from first-class modules don't unify

When you unpack `module(SomeModuleType)` from an array or option, the abstract types within become existentially quantified. Two independently unpacked modules have independent type identities — the compiler cannot prove `A.event = B.event` even if the user knows they're the same concrete type.

## Solution

Three coordinated changes:

### 1. Hoist the record type out of the functor

Move `type operations` from inside `DcbEventLog.T` to the `DcbEventLog` module level as a parameterized type:

```rescript
// DcbEventLog.res — top level, outside module type T
type operations<'event> = {
  read: read<'event>,
  append: append<'event>,
}

module type T = {
  module Spec: Spec
  type component = component<operations<Spec.event>>  // references the shared type
  let make: ...
}
```

Now ALL functor applications reference the single nominal type `DcbEventLog.operations<'event>`. Two instances with the same `'event` produce the same type.

### 2. Expose an abstract type for sharing constraints

Add `type dcbEvent` to `CommandHandler.T` so it can be constrained with `with type`:

```rescript
// CommandHandler.res
module type T = {
  type dcbEvent
  module Spec: Spec
  let make: (
    ~dcbEventLog: DcbEventLog.component<DcbEventLog.operations<dcbEvent>>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
```

The builder sets it concretely:
```rescript
// CommandHandler_Builder.res
module Make = (Spec: ..., Channel: ...):
  (CommandHandler.T with type dcbEvent = Spec.DcbEventLogSpec.event and module Spec = Spec) => {
  type dcbEvent = Spec.DcbEventLogSpec.event
  ...
}
```

### 3. Bundle related modules to thread the type

Instead of passing `~dcbSpec` and `~commandHandlers` as separate parameters (where their types are independently existential), bundle them into a single module type:

```rescript
// Plugin.res
module type DcbSpec = {
  @schema type event
  @schema type command
  let commandHandlers: array<module(CommandHandler.T with type dcbEvent = event)>
}
```

Inside `Plugin_Builder`, unpacking `module(DcbSpec)` gives a single `event` type. The `commandHandlers` array is already constrained with `with type dcbEvent = event`, so when unpacking each CommandHandler, `dcbEvent = DcbSpec.event` — matching the DcbEventLog's event type.

```rescript
// Plugin_Builder.res
| Some(module(DcbSpec)) =>
  module DcbEventLogSpec = { let name = name; @schema type event = DcbSpec.event }
  module DcbEventLog = DcbEventLog_Builder.Make(DcbEventLogSpec, ...)
  let dcbEventLog = DcbEventLog.make(...)

  DcbSpec.commandHandlers
  ->Array.map((module(CH: CommandHandler.T with type dcbEvent = DcbSpec.event)) => {
    let ch = CH.make(~dcbEventLog, ~opts)  // types now unify!
    (CH.Spec.name, ch->Component.outputs)
  })
```

## General Pattern

When you encounter this class of problem in ReScript:

1. **Never define record types inside functor outputs** if those records need to be shared across module boundaries. Hoist them to a stable module with type parameters.

2. **When multiple first-class modules must share a type**, bundle them into a single module type that carries the shared type. Use `with type` constraints on the array/option element type to tie the existential to the bundle's type.

3. **Expose abstract types** (`type dcbEvent`) on module types that will be packed as first-class modules, so callers can add `with type` constraints when needed.

### Anti-patterns

- Using `Obj.magic` or `%identity` externals to cast between structurally-identical but nominally-different types
- Passing separate parameters whose types are semantically linked but existentially independent
- Defining record types inside `module type T = { type t = {...} }` when the type must be shared across functor applications
