# AWS Deployment Strategy — App-Configurable Per Plugin/Aggregate

## Status: BACKLOG

## Goal

Let an app developer choose, per plugin and (optionally) per aggregate/read model,
which AWS deployment strategy is used — without hand-editing the generated
`Plugin.res`. Defaults to `Single` (one Lambda per plugin) and is overridable in
plugin metadata, not in the spec files.

---

## Background

Reventless ships several AWS deployment strategies for Aggregates and ReadModels:

- **Aggregate**: `Single` (default), `Single_Async`, `PerAggregate`, `Micro`, `NoResolver`
- **ReadModel**: `Single` (default), `PerReadModel`, `NoResolver`

Each is a separate functor under `ReventlessAws.{Aggregate,ReadModel}_Builder_<Strategy>`.
The current AWS Platform exposes only the `Single` defaults via
`Platform.Aggregate.Make` / `Platform.ReadModel.Make` (see [Platform.res](../../reventless/reventless-aws/src/Platform.res)),
and all other strategies require app developers to swap the builder at the call
site. Today's generated `Plugin.res` always picks `Single` because the codegen
calls the Platform default — there is no opt-in mechanism.

DCB slices (`StateChangeSlice`, `StateViewSlice`, `AutomationSlice`,
translations) and `ExtensionPoint`/`Extension` have a single strategy each, so
they don't need this.

---

## Why not PPX annotations on spec files

A spec like `Customer.res` describes the domain model — the same module is valid
whether deployed `Single`, `PerAggregate`, or `Micro`. Tagging it
`@@reventless.aggregate.strategy("PerAggregate")` couples deployment shape to
the spec, breaks portability across deployments, and forces the same choice on
every consumer of that spec package. Strategy is a deployment concern — keep it
near `heartbeatInterval` and Pulumi config.

---

## Proposal

### plugin.json — extend with optional `deploymentStrategy` block

```json
{
  "name": "Ordering",
  "heartbeatInterval": 60,
  "deploymentStrategy": {
    "aggregates": {
      "default": "Single",
      "Customer": "PerAggregate"
    },
    "readModels": {
      "default": "Single",
      "CustomersReadModel": "NoResolver"
    }
  }
}
```

- `default` (optional, default `"Single"`) — applies to every component of that
  kind unless overridden by name.
- Per-name overrides keyed by the spec name (e.g., `Customer`, not
  `CustomerAggregate`).
- Unknown strategy names are a hard error during `generate-plugin`.

The `Aws` codegen variant is the only consumer; Standard ignores it.

### Codegen change

- Extend [Pairing.aggregateDef](../../reventless/reventless-spec/src/generator/Pairing.res)
  with an `~strategy: string` resolved from plugin.json (default: `"Single"`).
- Same for `readModelDef`.
- `renderAggregates` (canonical) emits `Platform.Aggregate.Make(...)` for
  `Single`, `Platform.Aggregate.MakeAsync(...)` for `Single_Async`, and
  `ReventlessAws.Aggregate_Builder_<Strategy>.Make(...)` for the rest. The AWS
  variant of the renderer disappears for non-Single/Async paths because the
  Platform doesn't expose those — but this is the only place strategy choice
  matters.
- Same wiring for ReadModel.

### Platform layer

Optional follow-up: surface the non-default strategies on `Platform` so the
codegen can stay uniformly on `Platform.X.MakeY` and never reach into
`ReventlessAws.X_Builder_Y` directly:

```rescript
module Aggregate = {
  module Make = (...) => Aggregate_Builder_Single.Make(...)
  module MakeAsync = (...) => Aggregate_Builder_Single_Async.Make(...)
  module MakePerAggregate = (...) => Aggregate_Builder_PerAggregate.Make(...)
  module MakeMicro = (...) => Aggregate_Builder_Micro.Make(...)
  module MakeNoResolver = (...) => Aggregate_Builder_NoResolver.Make(...)
}
```

Same for `Platform.ReadModel`. This is a pure API surface change in
[reventless-aws/src/Platform.res](../../reventless/reventless-aws/src/Platform.res) —
no behaviour change.

---

## Steps

1. Document each strategy's contract (when to use, trade-offs) in
   [docs/reventless-aws/](../../packages/doc/docs/) — currently undocumented.
2. Surface every strategy on `Platform.{Aggregate,ReadModel}` so the codegen
   only emits `Platform.X.MakeY(...)`.
3. Extend [Config.res](../../reventless/reventless-spec/src/generator/Config.res)
   to read `deploymentStrategy` from plugin.json and pass it through to
   `Pairing.resolved`.
4. Map strategy name → `MakeY` suffix in `Codegen.res`. Validate unknown values
   in `generate-plugin` with a clear error.
5. Update [renderAggregates](../../reventless/reventless-spec/src/generator/Codegen.res)
   and `renderReadModels` to emit the strategy-specific `MakeY`. Default
   strategy emits the bare `Make` for backwards-compat with hand-written
   plugins.
6. Add an example: extend `examples/online-shop-hybrid/ordering/plugin.json`
   with `Customer` → `PerAggregate` (or similar) so the new path is exercised
   end-to-end.
7. Tests:
   - Codegen unit tests covering each strategy and the default case.
   - Pulumi preview test that asserts the generated stack actually creates
     N Lambdas for `PerAggregate` versus 1 for `Single`.

---

## Open questions

- Should `deploymentStrategy` also accept a wildcard glob (e.g., `"Order*":
  "PerAggregate"`)? Probably not — explicit names are easier to grep.
- ReadModel `Single_Async` doesn't exist today; symmetrical naming would be
  nice if the variants are added.
- Strategy choice for the *cross-stack* admin variant — defer until a real
  use case appears.

---

## Out of scope

- Strategy selection for slices, extension points, extensions, tasks. They
  have only one strategy today.
- Migration tooling for moving an existing aggregate from `Single` to
  `PerAggregate` (data layout differs — needs its own plan).
- Per-environment overrides (dev `Single`, prod `PerAggregate`). Could be
  supported by reading from Pulumi stack config instead of plugin.json, but
  adds complexity — keep plugin.json static for v1.
