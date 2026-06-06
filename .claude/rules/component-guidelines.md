# Component Development Guidelines

## Builder Pattern

All components use first-class modules for type-safe configuration:

```rescript
module type T = {
  module Spec: Reventless.Aggregate.Spec
  let make: (~opts: Pulumi.ComponentResource.options=?) => component
}
```

## Adapter Pattern

Separate deploy-time (Pulumi infrastructure) from runtime (Lambda handlers):
- `src/adapter/` — deploy-time adapter interfaces
- `src/adapter/Runtime/` — runtime builders for deployment strategies

## Backend-suffix Convention (`reventless-local`)

In the `reventless-local` package the `_InMemory` suffix is a **backend
discriminator**, not a platform label. Apply it only where a real storage-backend
choice exists:

- A storage surface with both an in-memory and a SQLite implementation carries the
  suffix on **both** files: `<Surface>Storage_InMemory.res` ⇄ `<Surface>Storage_Sqlite.res`
  (currently EventLog, DcbEventLog, QueryDb).
- Always-in-process adapters (bus, channels, publishers, runtime builders, etc.) have
  **no** backend alternative, so they carry **no** suffix. They are prefixed `Local`
  to disambiguate from same-named modules in `reventless-core` (`LocalBus`,
  `LocalQueryEngine`, `LocalCommandTopicChannel`, …).

Rule of thumb: add a `_Sqlite` arm → suffix both files `_InMemory`/`_Sqlite`;
in-process only → `Local`-prefixed, no suffix. Don't name a module bare (`Bus`,
`QueryEngine`) — it collides with the functor parameter `Bus` and with core modules
opened via `open Reventless`.

## Pulumi.Output.t Wrapping

All infrastructure values must be wrapped in `Pulumi.Output.t<'a>`:

- Never use `option<Pulumi.Output.t<'a>>` — this type doesn't work
- Never `...->ignore` on outputs — consume or assign them
- Prefer piped `output->Pulumi.Output.apply(fn)` over `Pulumi.Output.apply(output, fn)`
