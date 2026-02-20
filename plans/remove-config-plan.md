# Config Module — Full Removal

## Status: COMPLETED (branch `refactor/remove-config`, commit `dbcf5181`)

## Context

`Config.T` in `packages/reventless/src/Config.res` acted as a "global context" module threaded through the entire builder functor chain. The interface declared 5 fields but only `api` and `apiRole` were ever accessed via `Config.xxx`. The remaining fields (`userPool`, `userPoolId`, `scheduler`, `pluginName`) were dead surface area.

The refactoring applied the same explicit-parameter pattern as `~scheduler` already used, removing `Config.T` entirely from all inner builders and passing `~api` / `~apiRole` as explicit parameters.

---

## User-facing change

**Before** — user must define a Config module:
```rescript
module MyConfig = {
  type api = Pulumi.Output.t<AppSync.GraphQLApi.t>
  type role = Pulumi.Output.t<IAM.Role.t>
  type userPool = unit
  let pluginName = "my-plugin"
  let api = myGraphQLApi
  let apiRole = myRole
  let userPoolId = myUserPoolId
  let scheduler = myScheduler
}
module MyAgg = Aggregate_Builder.Make(MyConfig, MySpec, MyBehavior, MyEventMappings)
AWS.Plugin.make(~name, ~version, ..., ~scheduler, ~aggregates=[module(MyAgg)])
```

**After** — no Config module needed:
```rescript
module MyAgg = Aggregate_Builder.Make(MySpec, MyBehavior, MyEventMappings)
AWS.Plugin.make(~name, ~version, ..., ~api=myGraphQLApi, ~apiRole=myRole, ~scheduler,
                ~aggregates=[module(MyAgg)])
```

---

## Key Design Decisions

### 1. Counter: `T.make` does NOT get `~api`/`~apiRole`

Counter is used as a first-class module `module(Counter: Counter.T)` inside `EventMapper_Builder`, where `api`/`role` types are existential. Putting `~api`/`~apiRole` into `Counter.T.make` makes it impossible to call in that context.

**Fix**: `Counter_Builder.Make` gains an `ApiValues` module parameter that captures api/apiRole at functor application time. `Counter.T.make` signature is unchanged:

```rescript
module Make = (
  QueryDbStorage: QueryDb_Adapter.Storage,
  ApiValues: {
    let api: QueryDbStorage.api
    let apiRole: QueryDbStorage.role
  },
  Handler: Counter_Adapter.Handler,
): Counter.T
```

AWS `Counter_Builder.res` exposes this as a functor:
```rescript
module Make = (ApiValues: {
  let api: Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>
  let apiRole: Pulumi.Output.t<PulumiAws.IAM.Role.t>
}) => Reventless.Counter_Builder.Make(QueryDbStorage_DynamoDbStream, ApiValues, CounterHandler_DynamoDbStream)
```

### 2. `Plugin_Builder.Make` gains an `ApiSpec` module parameter

`Plugin_Builder.Make` has no functor parameter that carries `api`/`role` type information. Without a concrete definition, `type api` in the functor result is truly abstract — callers cannot coerce the result to `Plugin.T with type api = Pulumi.Output.t<AppSync.GraphQLApi.t>` because OCaml cannot verify the equality.

**Fix**: Add `ApiSpec: { type api; type role }` as the second parameter so the functor can define `type api = ApiSpec.api` concretely:

```rescript
module Make = (
  Spec: Spec,
  ApiSpec: { type api; type role },
  RuntimeEnvironment: ...,
  ...
): (Plugin.T with type api = ApiSpec.api and type role = ApiSpec.role) => {
  type api = ApiSpec.api
  type role = ApiSpec.role
  ...
}
```

AWS `Plugin.res` passes the concrete types inline:
```rescript
include Reventless.Plugin_Builder.Make(
  { let runtimeOps = ...; let resourceNaming = ...; let environment = ... },
  {
    type api = Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>
    type role = Pulumi.Output.t<PulumiAws.IAM.Role.t>
  },
  RuntimeEnvironment.Lambda,
  EventCollectorChannel.SQS,
  ...
)
```

### 3. `Plugin_Helpers` standalone functions use locally-abstract type parameters

Functions like `createAggregatesWithoutEventMappers`, `finishAggregates`, and `addEventMappers` are standalone module-level `let` bindings (not inside functors). Their `~api` parameter would normally be polymorphic `'a`, but OCaml cannot unify `'a` with the existential `SpecificAggregate.api` from an unpacked first-class module — the compiler rejects it with "type constructor would escape its scope".

**Fix**: Use `(type a)` locally-abstract type syntax so the constraint can be written explicitly in both the function signature and the module-unpack pattern:

```rescript
let createAggregatesWithoutEventMappers = (
  type a,
  aggregates: array<module(Aggregate.T with type api = a)>,
  ~api: a,
  opts,
) =>
  aggregates
  ->Array.map((module(SpecificAggregate: Aggregate.T with type api = a)) => {
    let aggregate = SpecificAggregate.make(~api, ~opts)
    ...
  })
```

Same pattern applied to `finishAggregates` and `addEventMappers`.

### 4. `QueryDb_Adapter.NoResolvers` self-reference

The original plan used `NoResolvers = (Storage: QueryDb_Adapter.Storage)`, but a file cannot reference itself by its own module name inside a functor parameter. Use the local module type name `Storage` instead:

```rescript
module NoResolvers = (Storage: Storage) => { ... }
```

### 5. `Aggregate.T` carries `type api` derived from `CommandGeneratorResolvers`

`Aggregate_Builder.Make` uses `CommandGeneratorResolvers.AppSync` (hardcoded in AWS builders), which has `type api = Pulumi.Output.t<AppSync.GraphQLApi.t>`. The builder exposes this as `type api = CommandGeneratorResolvers.api` in its result, making the aggregate modules type-safe for use in `array<module(Aggregate.T with type api = api)>`.

---

## Files Changed

### Deleted
- `packages/reventless/src/Config.res`
- `packages/reventless-aws/src/components/Config.res`

### Modified — reventless package

| File | Change |
|---|---|
| `components/CommandGenerator/CommandGenerator.res` | Added `type api` to `T`; `connect` takes `~api: api` |
| `components/CommandGenerator/CommandGenerator_Builder.res` | Removed `Config` param; `connect` gains `~api: Resolvers.api` |
| `components/QueryDb/QueryDb.res` | Added `type api`, `type role` to `T`; `make` takes `~api, ~apiRole` |
| `components/QueryDb/QueryDb_Builder.res` | Removed `Config` param; added `~api, ~apiRole` to `make` |
| `components/QueryDb/QueryDb_Adapter.res` | `NoResolvers` takes `Storage: Storage` (not `QueryDb_Adapter.Storage`) |
| `components/Aggregate/Aggregate.res` | Added `type api` to `T`; `make` takes `~api: api` |
| `components/Aggregate/Aggregate_Builder.res` | Removed `Config` param; `type api = CommandGeneratorResolvers.api` |
| `components/ReadModel/ReadModel.res` | Added `type api`, `type role` to `T`; `make` takes `~api, ~apiRole` |
| `components/ReadModel/ReadModel_Builder.res` | Removed `Config` param; added `~api, ~apiRole` to `make` |
| `components/Counter/Counter_Builder.res` | Removed `Config` param; added `ApiValues` module param |
| `components/Cloner.res` | Added `type api` to `T`; `Make` functor derives from `Runner.api` |
| `components/Plugin/Plugin.res` | Added `type api`, `type role` to `T`; array types use constraints |
| `components/Plugin/Plugin_Builder.res` | Added `ApiSpec` param; `type api = ApiSpec.api`; `construct`/`make` take `~api, ~apiRole` |
| `components/Plugin/Plugin_Helpers.res` | `createAggregatesWithoutEventMappers`, `finishAggregates`, `addEventMappers`, `createReadModels` use `(type a)` locally-abstract params |
| `core/Core/Core_Builder.res` | Removed `Config` param; `type api = ClonerRunner.api`; `make` takes `~api, ~apiRole` |

### Modified — reventless-aws package

| File | Change |
|---|---|
| `components/Aggregate_Builder_Single.res` | Dropped `Config` param from `Make` |
| `components/Aggregate_Builder_Micro.res` | Same |
| `components/Aggregate_Builder_PerAggregate.res` | Same |
| `components/ReadModel_Builder_Single.res` | Dropped `Config` param from `Make` |
| `components/ReadModel_Builder_PerReadModel.res` | Same |
| `components/ForeignReadModel_Builder.res` | Same |
| `components/Counter_Builder.res` | Changed to `module Make = (ApiValues: {...}) => Reventless.Counter_Builder.Make(...)` |
| `components/Plugin.res` | Passes inline `ApiSpec`; no longer needs type constraint wrapper |
| `core/Plugin_Aggregate_Builder.res` | Changed from functor to `include Aggregate_Builder_Single.Make(...)` |
| `core/Plugin_ReadModel_Builder.res` | Changed from functor to `include ReadModel_Builder_Single.Make(...)` |
| `core/Core_Builder.res` | Changed from functor to `include Reventless.Core_Builder.Make(...)` |

---

## Verification

Both packages compiled without errors:
```bash
cd packages/reventless && npm run build    # ✓ 203 modules
cd packages/reventless-aws && npm run build # ✓ 234 modules
```
