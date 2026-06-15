# Plan: Harmonize Plugin `make` Signature Across Aggregate / DCB / Hybrid

## Problem

The plugin-generator emits two different `make` signatures depending on which kinds the plugin contains:

- DCB plugins (no aggregates, no read models) get `let make = ()`.
- Aggregate / hybrid plugins get `let make = (~uiBundleUrl=?)`.

The platform contract is `module type PluginMaker = { let make: unit => Plugin.component }` (`reventless-local/src/Platform.res:689-691`), so the aggregate/hybrid case forces every composition root to write a `XxxMaker` wrapper that reads `<PLUGIN>_UI_BUNDLE_URL` from `process.env` and forwards it. The DCB case passes `module(Catalog)` bare.

The branch lives in `reventless-spec/src/generator/Codegen.res:643-644`:

```rescript
let hasUiComponents = resolved.aggregates->Array.length > 0 || resolved.readModels->Array.length > 0
let makeSig = hasUiComponents ? "  let make = (~uiBundleUrl=?) =>" : "  let make = () =>"
```

This is wrong for three reasons:

1. **Auto UI works without a bundle URL.** `RegisterFragments.res` (host-shell) derives panels/pages from `Platform_ComponentDefinitions` (built from `pluginStructure`). The `uiFragments` manifest only supplies per-fragment **federation overrides**: empty `remoteEntryUrl` ⇒ "no override; Auto UI renders this fragment." None of the current examples ship a federated UI bundle, so the entire `~uiBundleUrl` plumbing and the Maker-wrapper boilerplate are dead scaffolding.
2. **DCB plugins can't opt into a custom UI bundle at all.** The `hasUiComponents` check ignores DCB slice kinds, and `Plugin_Builder.makeAutoUIManifest` only accepts `~aggregates` / `~readModels` (`reventless-core/src/components/Plugin/Plugin_Builder.res:831-893`). So even when a DCB plugin later wants to override Auto UI with custom React, there's no door to walk through.
3. **Two composition-root styles for the same contract.** Today's `platform-local/src/Main.res` looks substantively different across the three example trees because of (1) and (2). The Maker pattern is presented as if it's an aggregate/hybrid-specific concern when it is really a "this plugin ships a custom bundle" concern that should apply uniformly.

## Goal

Every plugin starts with Auto UI (derived from `pluginStructure`) for free. Custom bundle override is opt-in and works identically for aggregate, DCB, and hybrid plugins. Composition roots write `module(Catalog)` bare in every case.

## Design

Move the `uiBundleUrl` read **inside** the generated `Plugin.res` (Composition variant), behind a zero-arg `make`. The signature stays `let make = ()` everywhere — same as today's DCB plugins — and the Composition file reads its own `<PLUGIN>_UI_BUNDLE_URL` env var. The AWS wrapper collapses to `let make = () => Composition.make()` since the env read is now in Composition. Auto UI manifest wiring is emitted for **every** plugin (aggregate, DCB, hybrid) so the override door is always open.

`makeAutoUIManifest` is widened to derive its fragmentId list from `pluginStructure` (which already enumerates all kinds), eliminating the per-kind argument arrays.

## Steps

### Step 1 — Widen `makeAutoUIManifest` to drive off `pluginStructure`

File: `reventless/reventless-core/src/components/Plugin/Plugin_Builder.res:831`

Replace the per-kind argument list with a single `~pluginStructure: Reventless.Plugin.pluginStructure` argument. Derive `panels` and `pages` by iterating the structure's `aggregates`, `readModels`, `stateChangeSlices`, `stateViewSlices`, and `stateViewSliceStreams` fields. Internal-visibility filter logic stays unchanged.

```rescript
let makeAutoUIManifest = (
  ~remoteEntryUrl: string,
  ~pluginStructure: Reventless.Plugin.pluginStructure,
  ~readModelPositions: array<string>=[],
  ~aggregatePositions: array<string>=[],
): Reventless.Plugin.uiFragmentManifest => { ... }
```

Mirror the same change in `Plugin.res` (signature export) and in `reventless-aws/src/Platform.res:1183` / `reventless-local/src/Platform.res:649` re-exports (they just re-bind the value — no actual surface change).

Tests: `reventless-core/tests/plugin/ManifestVisibilityTest.res` — adapt the test setup to pass `~pluginStructure` instead of the per-kind arrays.

### Step 2 — Generator: always emit `let make = ()` with the env-var read inline

File: `reventless/reventless-spec/src/generator/Codegen.res:517-700` (`renderComposition`)

Two changes:

- **Drop the `hasUiComponents` branch.** Always emit `let make = () =>` (same form DCB already gets).
- **Always emit the env-var read and the `~uiFragments` wiring.** At the top of the generated `Plugin.res` (inside the `Make` functor):

  ```rescript
  @val external uiBundleUrl: option<string> = "process.env.<PLUGIN>_UI_BUNDLE_URL"
  ```

  and inside the `Platform.Plugin.make(...)` call:

  ```rescript
  ~uiFragments=?uiBundleUrl->Option.map(url =>
    Platform.Plugin.makeAutoUIManifest(
      ~remoteEntryUrl=url,
      ~pluginStructure,
      ~readModelPositions=["platform-summary"],
      ~aggregatePositions=["resource-detail"],
    )
  ),
  ```

  Use `pluginNameToEnvBase` from `Codegen.res:474` for the env var name (already exists, currently used only by the AWS wrapper).

  Edge case: if the plugin has zero queryable kinds *and* zero command kinds (only extensions / tasks), the manifest can't host any override fragmentIds. Still emit the wiring — `Option.map(...)` on an empty manifest is harmless, and keeping the wiring uniform means the generator has no exceptions to remember.

### Step 3 — Generator: collapse the AWS wrapper

File: `reventless/reventless-spec/src/generator/Codegen.res:484-513` (`renderAwsWrapper`)

Drop the `hasUiComponents` parameter, the `externLines` block (env-var read), and the conditional `make` body. The wrapper becomes uniformly:

```rescript
let make = () => Composition.make()
```

Composition is now responsible for reading its own env var, so the AWS wrapper has nothing UI-specific left.

### Step 4 — Regenerate example plugins

Run `pnpm run generate` (or build, which triggers `prebuild`) across:

- `examples/online-shop-aggregates/catalog/`
- `examples/online-shop-aggregates/ordering/`
- `examples/online-shop-dcb/catalog/`
- `examples/online-shop-dcb/ordering/`
- `examples/online-shop-hybrid/catalog/`
- `examples/online-shop-hybrid/ordering/`
- `examples/online-shop-hybrid/catalog-aws/`
- `examples/online-shop-hybrid/ordering-aws/`

Expected diff:
- DCB plugins gain the env-var read + `~uiFragments=?` wiring at the call site (no behavior change unless env is set).
- Aggregate/hybrid plugins drop `~uiBundleUrl=?` from the `make` signature; the env read moves to the top of the file; the `~uiFragments=?` line stays.
- AWS variants drop the `@val external uiBundleUrl` line.

### Step 5 — Drop Maker wrappers in composition roots

Files:
- `examples/online-shop-aggregates/platform-local/src/Main.res`
- `examples/online-shop-hybrid/platform-local/src/Main.res`

Replace `CatalogMaker` / `OrderingMaker` with the DCB-style bare form:

```rescript
module Platform = ReventlessLocal.Platform.Make()

module Catalog = CatalogPlugin.Plugin.Make(Platform)
module Ordering = OrderingPlugin.Plugin.Make(Platform)

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(Catalog), module(Ordering)],
)

Platform.startServers()
```

All three platform-local Main.res files become identical (modulo plugin names).

### Step 6 — Update the docs guide

File: `packages/doc/docs-app/platform-and-plugin-guide.md:1617-1714` ("AutoUI" section)

- Drop the "When a plugin has at least one aggregate or read model …" carve-out — the env-var read and manifest wiring are now uniform across all plugin shapes.
- Remove the `CatalogMaker` example (lines 1656-1661). Show the bare `module(Catalog)` form for both local and AWS.
- Reframe the AutoUI section: "Auto UI works automatically from `pluginStructure`. The `<PLUGIN>_UI_BUNDLE_URL` env var supplies an *override* — a federated React bundle that replaces specific Auto UI fragments by id. Leaving it unset means every fragment renders via Auto UI."
- Sync the per-kind table (1682-1689) to include all DCB kinds explicitly.

### Step 7 — Verify

- `pnpm run build` at root — generator regenerates all plugin files; zero warnings.
- `pnpm test` for `reventless-core` (`ManifestVisibilityTest` updated) and `reventless-spec` (if any codegen tests exist — currently none).
- E2E spot check: start `examples/online-shop-aggregates/platform-local` with `CATALOG_UI_BUNDLE_URL` unset → Auto UI panels render in host-shell. Set `CATALOG_UI_BUNDLE_URL=http://localhost:5001` against a federation bundle → override kicks in. (Same check against `examples/online-shop-dcb/platform-local` to confirm the door now works for DCB too.)
- Sanity-check the AWS variant in `examples/online-shop-hybrid/catalog-aws` builds cleanly with the collapsed wrapper.

### Step 8 — Follow-ups in `reventless-tools/`

The harmonization is sourced entirely from this repo, but the tools repo carries a few stale references to the old "aggregate/hybrid Maker-wrapped" shape. None of them block the core change; address as part of the same workstream so the docs and golden trees don't drift.

- **`packages/reventless-create-app/test/WiringTest.res:54-86`** — the `makerMain` fixture and its two test cases (`"maker: binding goes after the real Make line, not the Maker module"`, `"maker: appends a bare module(<Name>) entry alongside the Maker entries"`) assert the wiring engine handles the Maker-wrapped Main.res. After harmonization no newly-generated example uses that shape. Two options:
  - **Keep** the cases relabeled "legacy shape still parses" — defensible if hand-written user Main.res files in the wild use the pattern.
  - **Drop** the fixture and both tests — framework is pre-stable (alpha), the example apps have always been the only consumers, and the engine's regex (`reventless-create-app/src/Wiring.res:19`) handles bare bindings unambiguously. Recommended.
  The engine code in `Wiring.res` does **not** change either way — it already handles both shapes correctly.

- **`packages/reventless-codegen/tests/golden/eventmodeling/catalog-minimal/src/Plugin.res`** and **`.../user-management/src/Plugin.res`** — after running the regenerated `generate-plugin`, these golden files gain a `@val external uiBundleUrl: …` line at the top of the `Make` functor and a `~uiFragments=?uiBundleUrl->Option.map(...)` clause inside `Platform.Plugin.make`. `ForwardGoldenTest.res:119` excludes `src/Plugin.res` from the golden diff (`isBuildArtefact`), so the test stays green — but the committed files will drift. Regenerate by re-running the prebuild against each golden tree and commit the result.

- **Analysis docs — one-line factual updates each:**
  - `docs/plans/new-plugin-scaffolding.md:88` — change "and Maker-wrapped layouts both recognized" to reflect that only the bare shape is now generated (legacy Maker layouts may still parse — depending on the decision above).
  - `docs/plans/reventless-vscode-app-bootstrap.md:107` — change "the three example `Main.res` shapes (dcb bare, aggregates/hybrid Maker-wrapped)" to "the single example `Main.res` shape (bare `module(<Name>)` entries across all three example trees)".

- **Zero impact** on `packages/reventless-vscode/src/**` — no direct references to `uiBundleUrl`, `Maker`, or the changed `makeAutoUIManifest` signature; the Phase 5/6 domain-graph work consumes `pluginStructure` (unchanged) via reventless-local, not the manifest builder.

- **Zero impact** on `packages/reventless-create-app/src/Bootstrap.res` — already emits the bare-`module(X)` skeleton; new apps were never Maker-wrapped.

Sequencing: land Steps 1-7 in core first; tools follow-ups can ship as a separate commit/PR in the tools repo once the new generator output is published, or via the `pnpm link:on` overlay against a local core checkout in the meantime.

## Notes / Out of Scope

- Federation **bundle authoring** for DCB-only plugins is a separate concern (the bundle has to know how to render slices). This plan only opens the door; the host-shell can already mount federated panels for any fragmentId regardless of which kind produced it.
- The `~readModelPositions` / `~aggregatePositions` arguments to `makeAutoUIManifest` are kept for now; they're used by the host-shell positioning logic. A follow-up could fold "positions" into `pluginStructure` itself but that's a larger surface change.
- This change does not affect the deployed contract — env-var names, the host-shell override behavior, and the published manifest schema all stay the same. Only the per-plugin Plugin.res file shape and the platform composition root change.
