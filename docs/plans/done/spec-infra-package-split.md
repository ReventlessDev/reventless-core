# Plan: reventless-spec / reventless-infra Package Split

**Status:** COMPLETE ✓
**Created:** 2026-03-02
**Completed:** 2026-03-02
**Analysis:** `docs/analysis/spec-infra-package-split.md`

---

## Context

`reventless-spec` (36 files, namespace `Reventless`) contains two fundamentally different
categories of types mixed together: behavioral contracts that application developers implement
(~10 files) and infrastructure plumbing that the framework uses internally (~26 files).
The mix exists because the dependency direction (spec cannot import core) forced infrastructure
types into spec.

The goal is to introduce a new middle package, `reventless-infra` (namespace `ReventlessInfra`),
that holds all infrastructure types. After the split:

- `reventless-spec` — pure behavioral contracts, `sury` the only dependency
- `reventless-infra` — infrastructure types + depends on spec + rescript-pulumi-pulumi + rescript-effect + rescript-uuid
- `reventless-core` — depends on both spec and infra
- Application plugin code — imports `reventless-infra` (transitively gets spec too)

The Alternative IaC Tool Support path is out of scope for this plan.

---

## New Package Location and Config

```
reventless/reventless-infra/
  package.json        name: @reventlessdev/reventless-infra, version: 3.0.0-alpha.0
  rescript.json       namespace: ReventlessInfra, subdirs: true
  src/
    (files as listed below)
```

**reventless-infra/rescript.json** dependencies:
```json
{
  "name": "@reventlessdev/reventless-infra",
  "namespace": "ReventlessInfra",
  "ppx-flags": ["sury-ppx/bin"],
  "warnings": { "error": "-44+101" },
  "sources": [{ "dir": "src", "subdirs": true }],
  "dependencies": [
    "sury",
    "@reventlessdev/rescript-pulumi-pulumi",
    "@reventlessdev/rescript-effect",
    "@reventlessdev/rescript-uuid",
    "@reventlessdev/reventless-spec"
  ]
}
```

Infra files reference spec types as `Reventless.*` (e.g. `Reventless.Aggregate.Spec`).

---

## Files: Complete Categorisation

### Files moved WHOLESALE to infra (no spec remnant; these files disappear from spec entirely)

All become `ReventlessInfra.<Module>` instead of `Reventless.<Module>`:

| Source in spec | Description |
|---|---|
| `src/adapter/Adapter.res` | Pulumi.Output-wrapped resource descriptor |
| `src/components/Component.res` | Pulumi ComponentResource wrapper — **also move hand-written `Component.js`** |
| `src/components/CommandGenerator.res` | outputs only |
| `src/components/CommandTopic.res` | publishJsons, commandsHandler, Effect/Stream types |
| `src/components/EventCollector.res` | outputs, enqueueEvent |
| `src/components/EventLog.res` | T constraint + outputs (no separate user-impl Spec) |
| `src/components/EventTopic.res` | publishJson, publishJsonStream, outputs |
| `src/components/Extension.res` | outputs, T wiring module type |
| `src/components/Heartbeat.res` | outputs |
| `src/components/QueryDb.res` | storageError, outputs |
| `src/components/Scheduler.res` | outputs, operations |
| `src/types/NoEventMappings.res` | Returns EventMapper.Mappings (infra due to Counter.T dep) |
| `src/types/Platform.res` | Platform.T abstract factory |
| `src/types/PluginExtensionPointSpec.res` | Core.Plugin protocol types |
| `src/types/ResourceNaming.res` | operations (validateName, urnName) |

### Files SPLIT (spec shrinks to domain portion; new infra file holds infrastructure portion)

Both packages can have `Aggregate.res` because they have different namespaces (`Reventless` vs `ReventlessInfra`).

| File | Spec keeps | Infra gets |
|---|---|---|
| `Aggregate.res` | `module type Spec` | `addEventMapper`, `outputs`, `allOutputs`, `operations`, `module type T` |
| `Counter.res` | `counterId`, `counterTarget`, `reference` (needed by EventMapping.action) | `countItem`, `outputs`, `operations`, `jsonEventsHandler`, `module type T` |
| `DcbEventLog.res` | `module type Spec` | `sequencedEvent`, `read`, `append`, streaming ops, `outputs`, `module type T` |
| `EventMapper.res` | `module type Target` (pure domain contract) | `module type Mappings` (Counter.T dep), `type outputs` |
| `ExtensionPoint.res` | `module type Spec`, `module type Mappings` | `outputs`, `module type T` |
| `Message.res` | `service`, `meta`, `context` (needed by Behavior.T, SideEffect.T) | `event'`, `command'`, `commandJson`, `statusChange`, `uuid`, encode, decode, `InvalidEvent` |
| `Plugin.res` | `name`, `version`, `extensionPointDefinition`, `extensionDefinition`, `extensionProtocol`, `pluginDefinition` | `DcbSpec` (StateChangeSlice.T dep), `outputs`, `module type T` |
| `ReadModel.res` | `module type Spec` + **all config types** (`subId`, `resolvedField`, `idResolverSourceConfig`, `config`, etc. — they are fields of Spec itself) | `outputs`, `operations`, `module type T` |
| `StateChangeSlice.res` | `module type Spec` | `operations`, `module type T` |
| `StateViewSlice.res` | `module type Spec` | `outputs`, `operations`, `module type T` |
| `Task.res` | `taskAction`, `bucketCallback`, `bucketMode`, `bucketSpec`, `sideEffects`, `config`, `module type Spec` | `queryBucketName`, `setup`, `outputs`, `operations`, `module type T` |

### Files that stay COMPLETELY in spec (unchanged)

`Behavior.res`, `DcbTag.res`, `EventMapping.res`, `ExtensionMapping.res`,
`ExtensionPointMapping.res`, `Handler.res`, `Id.res`, `Projection.res`,
`QueryEngine.res` (needed by SideEffect.T; no Pulumi/Effect/uuid deps),
`Schedule.res` (rate, schedule, create, delete — all plain types, sury only),
`SideEffect.res`

### reventless-spec rescript.json after split

Remove `@reventlessdev/rescript-pulumi-pulumi`, `@reventlessdev/rescript-effect`,
`@reventlessdev/rescript-uuid`. Dependencies become `["sury"]` only.

---

## Dependency Graph After Split

```
reventless-spec    (Reventless)       ← sury only
      ↑ imports
reventless-infra   (ReventlessInfra)  ← spec + pulumi + effect + uuid + sury
      ↑ imports
reventless-core    (ReventlessCore)   ← infra + spec (both namespaces needed)
      ↑ imports
reventless-aws                        ← infra + core + aws bindings
      ↑ imports
reventless-in-memory                  ← infra + core
```

Application plugin code (examples) → imports `reventless-infra` (gets `Reventless.*`
transitively for domain types, `ReventlessInfra.*` for infrastructure types).

---

## Implementation Phases

### Phase 1 — Scaffold reventless-infra package (1–2 h)

1. Create `reventless/reventless-infra/src/`
2. Write `package.json` (name, version, description, dependencies)
3. Write `rescript.json` (as above)
4. Update root `package.json` workspaces if not covered by `reventless/*` glob
5. Update root `rescript.json` dependencies to include `reventless-infra`
6. Update `lerna.json` if needed
7. Run `npm install` to resolve the new workspace package

### Phase 2 — Move pure-infra files from spec to infra (2–3 h)

For each of the 15 "wholesale" files listed above:
1. `cp` source to `reventless-infra/src/<Name>.res`
2. Remove from `reventless-spec/src/`
3. **Special**: copy `Component.js` (hand-written — do NOT let rescript build regenerate it)

No content changes in these files yet — they still say `Reventless.*` internally.
After all files are copied, fix all cross-references: infra files that reference each other
now use `ReventlessInfra.*`; infra files that reference spec types use `Reventless.*`.

Build `reventless-infra` in isolation to catch all broken cross-refs before moving on.

### Phase 3 — Split mixed files (1–2 days)

For each of the 11 split files:
1. Trim the spec file to its domain portion only
2. Create matching file in `reventless-infra/src/<Name>.res` with the infrastructure portion
3. Infra portion references spec types as `Reventless.<Module>.*`

Order matters — resolve inter-infra deps first:
1. `Counter.res` (needed by EventMapper)
2. `EventMapper.res` (needed by Aggregate and NoEventMappings)
3. `DcbEventLog.res`, `StateChangeSlice.res`, `StateViewSlice.res` (needed by Plugin.DcbSpec)
4. `Aggregate.res`, `ExtensionPoint.res`, `ReadModel.res`, `Task.res`, `Plugin.res`
5. `Message.res` (split service/meta/context into spec; rest into infra)

After each batch: `npm run build` in `reventless-infra` to verify.

### Phase 4 — Update reventless-spec rescript.json (30 min)

Remove `rescript-pulumi-pulumi`, `rescript-effect`, `rescript-uuid` from dependencies.
Rebuild spec standalone to confirm it compiles on `sury` only.

### Phase 5 — Update reventless-core (1–2 days)

`reventless/reventless/rescript.json`:
- Add `@reventlessdev/reventless-infra`
- Keep `@reventlessdev/reventless-spec`

Then update ~85 source files. Pattern: replace `Reventless.<InfraModule>` with
`ReventlessInfra.<InfraModule>` for infrastructure types; leave `Reventless.<DomainModule>`
for behavioral contracts.

**Infra modules** (all references become `ReventlessInfra.*`): Adapter, Component,
Aggregate (T/outputs/operations), CommandGenerator, CommandTopic, Counter (T/outputs),
DcbEventLog (T/operations), EventCollector, EventLog, EventMapper (Mappings/outputs),
EventTopic, Extension, ExtensionPoint (T/outputs), Heartbeat, NoEventMappings, Platform,
PluginExtensionPointSpec, Plugin (T/outputs/DcbSpec), QueryDb, ReadModel (T/outputs/operations),
ResourceNaming, Scheduler, StateChangeSlice (T/operations), StateViewSlice (T/operations),
Task (T/outputs/operations), Message (event'/command'/commandJson/uuid/encode/decode).

**Domain modules** (stay as `Reventless.*`): Aggregate.Spec, Behavior, Counter (counterId/counterTarget/reference),
DcbEventLog.Spec, EventMapper.Target, EventMapping, ExtensionMapping, ExtensionPoint (Spec/Mappings),
ExtensionPointMapping, Handler, Id, Message (meta/context/service), Plugin (pluginDefinition etc.),
Projection, QueryEngine.operations, ReadModel.Spec + config types, Schedule, SideEffect,
StateChangeSlice.Spec, StateViewSlice.Spec, Task.Spec + domain config types, DcbTag.

Approach: grep `Reventless\.` in reventless-core/src, then classify each occurrence.

### Phase 6 — Update reventless-aws (0.5 day)

- Add `@reventlessdev/reventless-infra` to rescript.json
- Update `Reventless.Platform.T` → `ReventlessInfra.Platform.T` and similar
- The AWS package implements `Platform.T` from infra — this is the key change

### Phase 7 — Update reventless-in-memory (0.5 day)

- Add `@reventlessdev/reventless-infra` to rescript.json
- Update namespace references; update all test files that reference `Reventless.Component.*`

### Phase 8 — Update examples and integration tests (0.5 day)

`examples/aggregate/` and `examples/dcb/`:
- Add `@reventlessdev/reventless-infra` to rescript.json + package.json
- In `CatalogPlugin.res`: `open Reventless` → `open ReventlessInfra` for Platform calls;
  domain module implementations (Spec, Behavior, Projection, etc.) are unchanged

### Phase 9 — Full build and test pass (1 day)

```bash
npm run build            # from monorepo root — catch all remaining type errors
npm test                 # run full test suite
```

Expected failure modes:
- Module name `Reventless.X` found where `ReventlessInfra.X` expected — grep and fix
- Functor application type mismatch at package boundary — trace which package owns the type
- `Component.js` accidentally regenerated — restore from git if needed

---

## Critical Files

| File | Role |
|---|---|
| `reventless/reventless-spec/rescript.json` | Remove pulumi/effect/uuid deps |
| `reventless/reventless-infra/rescript.json` | New file — new package config |
| `reventless/reventless-infra/src/Component.js` | Must be hand-written copy from spec; never regen |
| `reventless/reventless/rescript.json` | Add reventless-infra dep |
| `reventless/reventless-aws/rescript.json` | Add reventless-infra dep |
| `reventless/reventless-in-memory/rescript.json` | Add reventless-infra dep |
| `examples/aggregate/rescript.json`, `examples/dcb/rescript.json` | Add reventless-infra dep |
| `package.json` (root) | Workspaces — verify reventless/* glob covers infra |
| Root `rescript.json` | Add reventless-infra to dependencies for root ESM build |

---

## Key Risks

| Risk | Mitigation |
|---|---|
| Functor type identity failure at package boundary | Ensure each type is defined in exactly one package; infra references spec via `Reventless.*` |
| `Component.js` regenerated by rescript clean | Add comment; verify on each build step; restore from git if needed |
| Transitive ReScript deps not auto-exposed | List both `reventless-spec` AND `reventless-infra` explicitly in reventless-core's rescript.json |
| ~85 files in reventless-core to update | Build after each logical group of changes; use grep to track remaining refs |
| `Counter.counterId`/`counterTarget` in EventMapping.action | These stay in spec — verify no Pulumi/Effect/uuid deps on Counter's spec portion |

---

## Breaking Change for Application Code

After the split, application plugin assembly code changes:
```rescript
// Before
open Reventless
module CategoryAggregate = Platform.Aggregate.Make(Category, CategoryBehavior, NoEventMappings.Make(Category))

// After
open ReventlessInfra   // Platform, NoEventMappings now in infra
module CategoryAggregate = Platform.Aggregate.Make(Category, CategoryBehavior, NoEventMappings.Make(Category))
// Domain types (Category, CategoryBehavior) still satisfy Reventless.Aggregate.Spec — unchanged
```

Domain implementation files (Category.res, CategoryBehavior.res) are **unchanged** —
they only reference `Reventless.*` types which stay in spec.

---

## Verification

```bash
# 1. Spec standalone
cd reventless/reventless-spec && npm run build   # must compile on sury only

# 2. Infra standalone
cd reventless/reventless-infra && npm run build  # must compile

# 3. Core
cd reventless/reventless && npm run build        # ~85 file updates

# 4. Full monorepo
cd <root> && npm run build && npm test
```

---

## Effort Estimate

| Phase | Estimate |
|---|---|
| Scaffold | 1–2 h |
| Move pure-infra files | 2–3 h |
| Split mixed files | 1–2 days |
| Update spec rescript.json | 30 min |
| Update reventless-core | 1–2 days |
| Update reventless-aws + in-memory | 0.5 day |
| Update examples | 0.5 day |
| Build + test pass | 1 day |
| **Total** | **4–6 days** |

Estimates are calendar-day ranges for one developer working exclusively on this task.
Risk: medium. Main hazard is type-identity failures at functor application sites
(opaque error messages, require tracing which package owns each type).
