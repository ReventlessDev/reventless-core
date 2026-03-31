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

## Pulumi.Output.t Wrapping

All infrastructure values must be wrapped in `Pulumi.Output.t<'a>`:

- Never use `option<Pulumi.Output.t<'a>>` — this type doesn't work
- Never `...->ignore` on outputs — consume or assign them
- Prefer piped `output->Pulumi.Output.apply(fn)` over `Pulumi.Output.apply(output, fn)`
