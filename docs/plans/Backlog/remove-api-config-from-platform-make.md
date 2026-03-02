# Remove Api Config from Platform.Make

## Goal

Refactor AWS `Platform.Make` to no longer require `(Api: {let api; let apiRole})` as a functor argument. Instead, the Api component (created via `Platform.Api.Make(Config).make()`) provides the raw api/role values via its outputs. This decouples Platform creation from API resource provisioning.

**Prerequisite**: The platform-plugin-core-extension plan must be completed first (adds Plugin/Core/makeScheduler/makePlatform to Platform.T).

---

## Problem

Currently `Platform.Make` takes raw `api`/`apiRole` values at functor time:
```rescript
module Make = (Api: {
  let api: Types.AppSync.api
  let apiRole: Types.AppSync.role
}): ReventlessInfra.Platform.T
```

This means the AppSync API must be created _before_ the Platform. But the Platform's `Api.Make` functor should be the one creating the API — not the caller.

**Blocked by**: `Counter_Builder.Make(Api)` and `StateViewSlice_Builder.Make(Api)` both take api/apiRole at functor time (not at `make()` call time). Removing the Api config requires refactoring these builders first.

---

## Steps

### 1. Update `Api.outputs` to include raw api/role references

**File**: `reventless/reventless-infra/src/components/Api.res`

Currently:
```rescript
type outputs = {
  apiId: Pulumi.Output.t<string>,
}
```

Add raw resource references:
```rescript
type outputs<'api, 'role> = {
  apiId: Pulumi.Output.t<string>,
  api: Pulumi.Output.t<'api>,
  role: Pulumi.Output.t<'role>,
}
```

Update `Api_Builder.Make` to populate these from `Provider.makeApiResource` return values.

### 2. Refactor `Counter.T` to accept api/apiRole at make-time

**Files**:
- `reventless-infra/src/components/Counter.res` — add `type api`, `type role`, `~api: api`, `~apiRole: role` to `Counter.T.make`
- `reventless-core/src/components/Counter/Counter_Builder.res` — move Api usage from functor param to `construct` function
- `reventless-aws/src/components/Counter_Builder.res` — remove `(Api: ...)` functor param
- `reventless-in-memory/src/components/Counter_Builder.res` — update if needed
- `reventless-aws/src/Platform.res` — update `module Counter` wiring

### 3. Refactor `StateViewSlice_Builder` similarly

**Files**:
- `reventless-infra/src/components/StateViewSlice.res` — add api/role to module type
- `reventless-core/src/components/StateViewSlice/StateViewSlice_Builder.res` — refactor
- `reventless-aws/src/components/StateViewSlice_Builder.res` — remove Api functor param
- `reventless-aws/src/Platform.res` — update wiring

### 4. Remove `(Api: ...)` from AWS `Platform.Make`

**File**: `reventless/reventless-aws/src/Platform.res`

Change from:
```rescript
module Make = (Api: {
  let api: Types.AppSync.api
  let apiRole: Types.AppSync.role
}): ReventlessInfra.Platform.T
```

To:
```rescript
module Make = (): ReventlessInfra.Platform.T
  with type api = Types.AppSync.api
  and type role = Types.AppSync.role
```

Counter and StateViewSlice now get api/role at make-time from callers, who extract them from `Api.component.outputs`.

### 5. (Optional) Change `Core.T` to take `~api: Api.component`

Replace `~api: api, ~apiRole: role, ~apiComponent: Api.component=?` with just `~api: Api.component` in `Core.T`. Core extracts raw api/role from Api component outputs internally.

---

## Open Questions

1. **`Api.outputs` type parameterization** — Making outputs generic (`outputs<'api, 'role>`) changes all callers. Alternative: keep `Api.outputs` concrete per platform (not polymorphic) and use platform-level `type api`/`type role` from `Platform.T`.

2. **Counter.T backward compatibility** — Adding `~api`/`~apiRole` to `Counter.T.make` changes the public interface. All Counter callers must be updated.

3. **Sequencing** — This refactoring touches many files. Consider doing Counter first, then StateViewSlice, then Platform.Make removal, with a build check between each.
