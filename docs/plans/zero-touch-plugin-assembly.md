# Plan: Zero-Touch Plugin Assembly

## Summary

Eliminate the need to edit the plugin composition root when adding a new component. A developer creates a file in the right folder; the next build auto-generates `src/Plugin.res` and compiles it.

**Source analysis:** `docs/analysis/zero-touch-plugin-assembly.md`

---

## Prerequisites

- Convention change 1 applied: every `Extension/` file has its inner mapping module named `Mapping` (not `DemandMapping`, `ProductMapping`, etc.)
- Convention change 2 applied: every `*Projections.res` file exports `let allMappings`
- Framework change applied: `Platform.ExtensionPoint.Make` drops the `Config: {let moduleUrl}` parameter; `ExtensionPoint_Builder.res` (AWS) uses `Mapping.moduleUrl` as `mappingsModulePath`

---

## Phase 1 — Convention changes in existing plugins

Apply the two required convention changes to both example plugins and any real plugin.

**Files affected:**

| Change | Files |
|---|---|
| Rename inner module to `Mapping` | `src/Extension/*.res` in every plugin |
| Add `allMappings` export | `src/ReadModel/*Projections.res` in every plugin |

**Steps:**

1. In each `Extension/` file: rename the inner mapping module (e.g. `DemandMapping` → `Mapping`); update all internal references
2. In each `*Projections.res` file: add `let allMappings: array<module(Mapping)> = [module(...), ...]` at the end, listing existing mapping sub-modules
3. Update any callers (plugin composition roots, tests) that reference the old sub-module names

**Verification:** existing plugin tests and E2E tests still pass.

---

## Phase 2 — Framework change: drop `Config` from `ExtensionPoint.Make`

Remove the `Config: {let moduleUrl}` parameter from `Platform.ExtensionPoint.Make` and its variants (`Make2`, `Make3`).

**Files:**

- `reventless/reventless-infra/src/types/Platform.res` — remove `Config` parameter from `ExtensionPoint.Make`, `Make2`, `Make3`
- `reventless/reventless-aws/src/components/ExtensionPoint_Builder.res` — replace `Mappings.moduleUrl` with `Mapping.moduleUrl` (the first mapping's URL) as `mappingsModulePath`
- `reventless/reventless-in-memory/src/components/ExtensionPoint_Builder.res` — remove `Config` parameter (in-memory builder ignores `moduleUrl` anyway)
- All call sites in example plugins and real plugins — remove `{let moduleUrl: string = %raw(...)}` second argument

**Verification:** deploy smoke test; AWS bundler resolves the correct mapping module path.

---

## Phase 3 — Generator: `Config.res`

Implement `reventless-spec/src/generator/Config.res`.

Reads `plugin.json` from the `src/` directory (or applies defaults if absent):
- `name` — derived from `package.json` `"name"` field (unscoped, hyphen/underscore → PascalCase)
- `heartbeatInterval` — default `60`
- `exclude` — default `[]`, supports file paths and glob patterns relative to `src/`

```rescript
type config = {
  name: string,
  heartbeatInterval: int,
  exclude: array<string>,
}

let read: (~srcDir: string) => config
```

**Verification:** unit test with and without `plugin.json` present.

---

## Phase 4 — Generator: `Discovery.res`

Implement `reventless-spec/src/generator/Discovery.res`.

Walks the `src/` directory tree and classifies files by their parent folder name. Returns structured data grouping files by component type.

Folder→type mapping (case-sensitive):

| Folder names | Component type |
|---|---|
| `StateChange[s][Slice[s]]` | `StateChangeSlice` |
| `StateView[s][Slice[s]]` | `StateViewSlice` |
| `Automation[s][Slice[s]]` | `AutomationSlice` |
| `InboundTranslation[s][Slice[s]]` | `InboundTranslationSlice` |
| `OutboundTranslation[s][Slice[s]]` | `OutboundTranslationSlice` |
| `Aggregate[s]` | `Aggregate` |
| `ReadModel[s]` | `ReadModel` |
| `Task[s]` | `Task` |
| `ExtensionPoint[s]` | `ExtensionPoint` |
| `Extension[s]` | `Extension` |

Excluded always: `Plugin/`, `tests/`, `lib/`, `*Test.res`, `*Fixtures.res`. Also excludes any path matching the `config.exclude` patterns.

ExtensionPoint folders: if the immediate children are subfolders (not `.res` files), each subfolder is treated as a separate EP group.

```rescript
type componentType =
  | StateChangeSlice | StateViewSlice | AutomationSlice
  | InboundTranslationSlice | OutboundTranslationSlice
  | Aggregate | ReadModel | Task | ExtensionPoint | Extension

type discoveredFile = {stem: string, componentType: componentType, epGroup: option<string>}

let scan: (~srcDir: string, ~exclude: array<string>) => array<discoveredFile>
```

**Verification:** unit test against a fixture directory tree covering all folder name variants, plural forms, chapters, and exclude patterns.

---

## Phase 5 — Generator: `Pairing.res`

Implement `reventless-spec/src/generator/Pairing.res`.

Applies pairing rules to the flat list from `Discovery`:

- **Aggregate:** pair `Foo` + `FooBehavior`; look for `Foo_EventMappings` anywhere under `src/EventMappings/`; skip unpaired stems (warn)
- **ReadModel:** pair `FooReadModel` + `FooProjections`; skip unpaired (warn)
- **ExtensionPoint:** group by EP group name; count mapping files; select `Make` / `Make2` / `Make3` / `MakeMulti`
- All other types: no pairing needed

```rescript
type aggregateDef = {spec: string, behavior: string, eventMappings: option<string>}
type readModelDef = {readModel: string, projections: string}
type extensionPointDef = {group: option<string>, mappings: array<string>}

type resolved = {
  stateChangeSlices: array<string>,
  stateViewSlices: array<string>,
  automationSlices: array<string>,
  inboundTranslationSlices: array<string>,
  outboundTranslationSlices: array<string>,
  aggregates: array<aggregateDef>,
  readModels: array<readModelDef>,
  tasks: array<string>,
  extensionPoints: array<extensionPointDef>,
  extensions: array<string>,
}

let resolve: (array<Discovery.discoveredFile>, ~srcDir: string) => resolved
```

**Verification:** unit tests for all pairing cases including unpaired warnings and EP group counting.

---

## Phase 6 — Generator: `Codegen.res`

Implement `reventless-spec/src/generator/Codegen.res`.

Renders the `resolved` data into a `Plugin.res` source string. Produces module bindings in declaration order, then `Plugin.make` call with parameters in `Plugin_Builder.make` order:

```
~name, ~heartbeatInterval,
~extensionPoints, ~extensions,
~aggregates, ~readModels, ~tasks,
~stateChangeSlices, ~stateViewSlices, ~automationSlices,
~outboundTranslationSlices, ~inboundTranslationSlices
```

Omits any `~param=[]` call (uses ReScript's optional parameter default). Emits `open Reventless.Projection` only when ReadModels are present.

For `MakeMulti` EP groups (4+ mappings), emits the inline module expression.

```rescript
let render: (~config: Config.config, ~resolved: Pairing.resolved) => string
```

**Verification:** snapshot tests comparing rendered output against the expected `Plugin.res` for both DCB catalog and aggregate catalog fixtures.

---

## Phase 7 — Generator: `PluginGenerator.res` (entry point)

Implement `reventless-spec/src/generator/PluginGenerator.res`.

Entry point: reads `Process.argv[2]` as `srcDir`, orchestrates the pipeline, writes `src/Plugin.res`. Adds a shebang line comment so it can be invoked directly.

```rescript
// #!/usr/bin/env node
// (ReScript doesn't support actual shebang — add to compiled .mjs via postbuild)
```

Since ReScript can't emit a shebang, add a one-line `postbuild` script in `reventless-spec/package.json` that prepends `#!/usr/bin/env node\n` to the compiled file.

Wire up `package.json`:

```json
{
  "bin": {
    "generate-plugin": "./src/generator/PluginGenerator.res.mjs"
  },
  "scripts": {
    "postbuild": "node -e \"const f='src/generator/PluginGenerator.res.mjs'; const fs=require('fs'); const c=fs.readFileSync(f,'utf8'); if(!c.startsWith('#!')) fs.writeFileSync(f,'#!/usr/bin/env node\\n'+c); require('fs').chmodSync(f, 0o755)\""
  }
}
```

**Verification:** run `generate-plugin examples/online-shop-dcb/catalog/src/` and diff against the expected `Plugin.res`.

---

## Phase 8 — Wire into example plugins

Replace hand-authored composition roots with the generator in both example plugins.

**For each plugin (`catalog`, `ordering` in both `online-shop-dcb` and `online-shop-aggregates`):**

1. Add `"generate"` and `"prebuild"` scripts to `package.json`
2. Run `npm run generate` to produce `src/Plugin.res`
3. Delete the hand-authored `src/Plugin/CatalogPlugin.res` (or `OrderingPlugin.res`)
4. Update `platform-in-memory/src/Main.res`: `CatalogPlugin.Make` → `Catalog.Plugin.Make`
5. Build and run all tests

**Verification:** full monorepo build passes; all E2E and unit tests pass.

---

## Phase 9 — Documentation

Update every guide and doc page that describes or references the old hand-authored plugin composition root.

### `docs/guides/platform-and-plugin-guide.md` ★ primary

The canonical guide. Full rewrite of the plugin composition section:
- Remove the "create `CatalogPlugin.res`" step
- Replace with: create `src/plugin.json` (optional), add `generate` script to `package.json`, run `npm run build`
- Document the folder conventions for each component type
- Document the `allMappings` export convention for Projections files
- Document the `Mapping` module name convention for Extension files
- Document conditional exclusion via `"exclude"` in `plugin.json`

### `docs/guides/dcb-usage.md`

Line 341 has an inline `CatalogPlugin` example of a DCB plugin composition root. Replace with the generated-file pattern and folder structure.

### `docs/guides/application-development-layers.md`

Multiple references to `CatalogPlugin.Make(Platform)` and "composition root" as a hand-authored concept:
- Lines 606, 610, 638–639, 642: update module reference from `CatalogPlugin.Make` to `Catalog.Plugin.Make`
- Lines 557, 629, 645, 655: update prose — the composition root is now `src/Plugin.res` (generated); the platform wiring file (`Main.res`) remains the place that selects the concrete platform
- Line 773, 779: update `ItemsPlugin.Make` to `Items.Plugin.Make` pattern

### `docs/guides/deployment-guide.md`

- Line 117: folder tree shows `src/CatalogPlugin.res` → replace with `src/Plugin.res` (generated) and `src/plugin.json` (optional)
- Lines 167, 184–185: update module references from `CatalogPlugin.CatalogPlugin.Make` to `Catalog.Plugin.Make`

### `docs/guides/lambda-deployment.md`

- Line 82: diagram label `CatalogPlugin.res (Layer 2 — platform-agnostic)` → `Plugin.res (auto-generated)`
- Line 90: update architecture diagram row
- Line 118: code snippet for Layer 3 composition — update file reference
- Line 243: folder tree shows `Plugin/` subfolder → replace with flat `Plugin.res`
- Lines 335, 374, 391: update `CatalogPlugin.Make` → `Catalog.Plugin.Make`; update prose about platform-agnostic plugin files

### `docs/guides/reventless-ppx.md`

- Line 454: `@resolves` example uses `plugin: "CatalogPlugin"` — check whether this string refers to the plugin name (unchanged) or the file/module name (changed); update if the latter
- Line 635: PPX naming table shows `CatalogPlugin` as an example plugin package name → update to reflect that plugin name is now derived from `package.json` or `plugin.json`

### `docs/guides/output-types-in-reventless-spec.md`

Mentions `Plugin_Helpers.res` file paths — these are framework internals and don't change, but verify no paths reference the now-deleted `Plugin/CatalogPlugin.res` structure.

### `CLAUDE.md`

Add a note under the component structure section:
- Plugin composition roots are auto-generated as `src/Plugin.res` by `generate-plugin` (from `reventless-spec`)
- `prebuild` script runs the generator before `rescript build`
- The generated file is committed to git

### `reventless-spec/README.md`

Add `generate-plugin` CLI usage section:
- Installation / invocation
- Folder conventions reference
- `plugin.json` fields
- `allMappings` and `Mapping` module conventions

---

## Status

| Phase | Status |
|---|---|
| Phase 1 — Convention changes | ⬜ Not started |
| Phase 2 — Drop Config from ExtensionPoint.Make | ⬜ Not started |
| Phase 3 — Config.res | ⬜ Not started |
| Phase 4 — Discovery.res | ⬜ Not started |
| Phase 5 — Pairing.res | ⬜ Not started |
| Phase 6 — Codegen.res | ⬜ Not started |
| Phase 7 — PluginGenerator.res entry point | ⬜ Not started |
| Phase 8 — Wire into example plugins | ⬜ Not started |
| Phase 9 — Documentation | ⬜ Not started |
