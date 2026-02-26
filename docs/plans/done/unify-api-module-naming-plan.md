# Unify API Module Naming Across Component Builders

## Status: done

## Problem

The functor parameter that bundles `api`/`apiRole` values (or declares their types) is
named inconsistently across packages:

| File | Before | Carries | After |
|------|--------|---------|-------|
| `reventless-core` `Counter_Builder.res` | `ApiValues` | values (`let api`, `let apiRole`) | `Api` ✓ |
| `reventless-core` `Plugin_Builder.res` | `ApiSpec` | types only (`type api`, `type role`) | `ApiSpec` ✓ unchanged |
| `reventless-core` `StateViewSlice_Builder.res` | `Api` | values | `Api` ✓ already correct |
| `reventless-aws` `Platform.res` | `ApiValues` | values | `Api` ✓ |
| `reventless-aws` `Counter_Builder.res` | `ApiValues` | values | `Api` ✓ |
| `reventless-aws` `StateViewSlice_Builder.res` | `ApiValues` | values | `Api` ✓ |
| `reventless-in-memory` `Counter_Builder.res` | *(anonymous inline)* | values | `Api` ✓ extracted as named |
| `reventless-in-memory` `StateViewSlice_Builder.res` | `InMemoryApi` | values | `Api` ✓ |

## Convention

- **Values module** (`let api = ...`, `let apiRole = ...`) → **`Api`**
- **Types-only module** (`type api`, `type role`) → **`ApiSpec`** (Plugin_Builder already used this; kept as-is)

All renames are purely internal to each functor body — none of these names are part of
any externally visible module type. No callers need to change.

---

## Step 1 — `reventless-core/Counter_Builder.res`

Rename the functor parameter `ApiValues` → `Api`, and update all body references.

**Before:**
```rescript
module Make = (
  QueryDbStorage: QueryDb_Adapter.Storage,
  ApiValues: {
    let api: QueryDbStorage.api
    let apiRole: QueryDbStorage.role
  },
  Handler: Counter_Adapter.Handler,
): Counter.T => {
  ...
  let referencesDb = ReferencesDb.make(~api=ApiValues.api, ~apiRole=ApiValues.apiRole, ...)
  let countsDb = CountsDb.make(~api=ApiValues.api, ~apiRole=ApiValues.apiRole, ...)
```

**After:**
```rescript
module Make = (
  QueryDbStorage: QueryDb_Adapter.Storage,
  Api: {
    let api: QueryDbStorage.api
    let apiRole: QueryDbStorage.role
  },
  Handler: Counter_Adapter.Handler,
): Counter.T => {
  ...
  let referencesDb = ReferencesDb.make(~api=Api.api, ~apiRole=Api.apiRole, ...)
  let countsDb = CountsDb.make(~api=Api.api, ~apiRole=Api.apiRole, ...)
```

---

## Step 2 — `reventless-core/Plugin_Builder.res`

**No change.** `ApiSpec` carries only types (`type api`, `type role`) and already follows the
`ApiSpec` convention for types-only modules. Decision: keep `ApiSpec` as the canonical name
for type-only API parameters (matches existing usage and is more descriptive than `ApiTypes`).

---

## Step 3 — `reventless-aws/Platform.res`

Rename the functor parameter `ApiValues` → `Api`, and update body references.

**Before:**
```rescript
module Make = (ApiValues: {
  let api: Types.AppSync.api
  let apiRole: Types.AppSync.role
}): Reventless.Platform.T => {
  ...
  module Counter = Counter_Builder.Make(ApiValues)
  module StateViewSlice = StateViewSlice_Builder.Make(ApiValues)
```

**After:**
```rescript
module Make = (Api: {
  let api: Types.AppSync.api
  let apiRole: Types.AppSync.role
}): Reventless.Platform.T => {
  ...
  module Counter = Counter_Builder.Make(Api)
  module StateViewSlice = StateViewSlice_Builder.Make(Api)
```

---

## Step 4 — `reventless-aws/Counter_Builder.res`

Rename the functor parameter `ApiValues` → `Api`.

**Before:**
```rescript
module Make = (ApiValues: {
  let api: Types.AppSync.api
  let apiRole: Types.AppSync.role
}) => ReventlessCore.Counter_Builder.Make(
  QueryDbStorage_DynamoDbStream,
  ApiValues,
  CounterHandler_DynamoDbStream,
)
```

**After:**
```rescript
module Make = (Api: {
  let api: Types.AppSync.api
  let apiRole: Types.AppSync.role
}) => ReventlessCore.Counter_Builder.Make(
  QueryDbStorage_DynamoDbStream,
  Api,
  CounterHandler_DynamoDbStream,
)
```

---

## Step 5 — `reventless-aws/StateViewSlice_Builder.res`

Rename the functor parameter `ApiValues` → `Api`.

**Before:**
```rescript
module Make = (ApiValues: {
  let api: Types.AppSync.api
  let apiRole: Types.AppSync.role
}) => ReventlessCore.StateViewSlice_Builder.Make(
  ...
  ApiValues,
)
```

**After:**
```rescript
module Make = (Api: {
  let api: Types.AppSync.api
  let apiRole: Types.AppSync.role
}) => ReventlessCore.StateViewSlice_Builder.Make(
  ...
  Api,
)
```

---

## Step 6 — `reventless-in-memory/Counter_Builder.res`

Extract the anonymous inline module as a named `Api` module.

**Before:**
```rescript
module Make = (Bus: InMemory_Bus.T) => {
  module QueryDbStorage = QueryDbStorage_InMemory.Make(Bus)
  include ReventlessCore.Counter_Builder.Make(
    QueryDbStorage,
    {
      let api = ()
      let apiRole = ()
    },
    CounterHandler_InMemory,
  )
}
```

**After:**
```rescript
module Make = (Bus: InMemory_Bus.T) => {
  module QueryDbStorage = QueryDbStorage_InMemory.Make(Bus)
  module Api = {
    let api = ()
    let apiRole = ()
  }
  include ReventlessCore.Counter_Builder.Make(
    QueryDbStorage,
    Api,
    CounterHandler_InMemory,
  )
}
```

---

## Step 7 — `reventless-in-memory/StateViewSlice_Builder.res`

Rename `InMemoryApi` → `Api`.

**Before:**
```rescript
  module InMemoryApi = {
    let api = ()
    let apiRole = ()
  }

  module CoreMaker = ReventlessCore.StateViewSlice_Builder.Make(
    RuntimeEnvironment,
    QueryDbStorage,
    QueryDbResolvers,
    EventCollectorChannel,
    EventCollectorRuntimeBuilder,
    InMemoryApi,
  )
```

**After:**
```rescript
  module Api = {
    let api = ()
    let apiRole = ()
  }

  module CoreMaker = ReventlessCore.StateViewSlice_Builder.Make(
    RuntimeEnvironment,
    QueryDbStorage,
    QueryDbResolvers,
    EventCollectorChannel,
    EventCollectorRuntimeBuilder,
    Api,
  )
```

---

## Step 8 — Build and verify

```bash
npm run build
cd reventless/reventless-in-memory && npm test
```

All tests must pass (no behaviour change — purely cosmetic renames internal to each functor).
