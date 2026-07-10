# Plan: Surface component **chapter** grouping in the deployed plugin structure

**Date:** 2026-07-10

**Status:** DONE (implemented + build/test-verified) — see "Implementation" below.

**Relates to:** [deploy-hook-dcb-slice-schema-parity.md](deploy-hook-dcb-slice-schema-parity.md)
(same "a signal the tooling knows at authoring time never reaches deployed consumers"
shape, different datum).

---

## Goal

Make a component's **chapter** (its intra-plugin grouping band — the sub-boxes that
partition a plugin's Event Graph into feature areas) a **build-captured, deploy-surfaced**
datum, so a consumer that renders the graph from the platform's **deployed read models**
(no workspace/disk access) groups components into chapters identically to the authoring
tooling.

## Background — where the asymmetry is

Chapter membership today is a **filesystem convention inferred at authoring time**, with no
representation in the framework:

- The authoring tool derives a component's chapter from its **source path**: the first
  path segment under the plugin's `src/` that is not a recognised kind-folder
  (`chapterOf`: `src/<Chapter>/…/<Component>.res` → `"<Chapter>"`; segments in the
  kind-folder set — aggregates/slices/… — yield "no chapter"). Purely disk-derived.
- Nothing in the compiled component carries this. At **runtime** a ReScript module does not
  know its own source directory, so neither `Plugin_Structure` (the static plugin
  definition) nor the onPluginBuilt hook records a chapter. The deployed plugin-structure
  read model therefore has no chapter field at all.

Consequence: a deployed-graph consumer renders each plugin as **one flat container**; the
chaptered layout (e.g. a "Products" band and a "Categories" band inside one plugin) only
exists in the workspace tool that can read the folder layout.

## Approach

Capture the chapter at **compile time**, where the source path IS available, and thread it
to the deployed read model:

1. **PPX / codegen capture.** The spec PPX (or the component-registration codegen) has the
   `.res` source path at expansion time. Derive the chapter with the **same heuristic** the
   authoring tool uses — first `src/` sub-segment that is not in the shared kind-folder set —
   and emit it as component metadata (e.g. `~chapter=?`). Keeping the heuristic identical is
   the whole point: a chapter read off disk (pre-deploy) and a chapter read off the deployed
   read model must **agree** so they dedup, never conflict.
   - *Alternative considered:* an explicit `@chapter("Products")` spec annotation
     (author-declared). Rejected as the primary path — it duplicates the folder convention
     and drifts from the existing tool behaviour; keep it only as an optional override.

2. **Thread through the structure.** Add `chapter: option<string>` to the per-component
   records `Plugin_Structure` builds (aggregates / slices / views / translation slices —
   every kind that can carry a graph node), sourced from the PPX metadata. Mirror it on the
   onPluginBuilt hook's `pluginDeployedSchema` for parity with the other per-component
   metadata already there.

3. **Persist to the deployed read model.** Ensure the plugin-structure read model (the one
   surfaced as the deployed plugin structure) carries `chapter` per component through its
   Sury schema + projection, so it survives the definition → read-model round-trip.

4. **Shared derivation reads it.** In the shared graph-derivation surface, expose the
   per-node chapter so both the workspace tool and a headless consumer feed identical
   `chapters` to the graph renderer's chapter-band parameter — the renderer already supports
   chapter sub-containers; only the *data* is missing on the deployed side.

## Definition of done

- [x] Component metadata carries a `chapter` captured at build time using the same
      first-non-kind-`src`-segment heuristic as the authoring tool.
- [x] `Plugin_Structure` + the onPluginBuilt hook expose `chapter?` per component.
- [x] The deployed plugin-structure read model round-trips `chapter`.
- [x] Headless test: a component whose source lives under `src/Foo/…` reports chapter
      `"Foo"`; one directly under a kind-folder reports none.
- [x] Zero-regression build + suite.
- [ ] CHANGELOG note (neutral: "plugin structure now carries per-component chapter grouping,
      so deployed-graph consumers render chapter bands without workspace access"). *(added
      via the conventional-commit `feat:` message; Lerna generates the CHANGELOG entry.)*

## Risks / notes

- **PPX source-path access.** Confirm the PPX/codegen stage can read the expanding file's
  path portably (it drives the whole approach). If not, fall back to the `@chapter`
  annotation path.
- **Heuristic parity.** The kind-folder exclusion set must match the authoring tool's
  exactly, or a reflected chapter won't dedup a disk one. Factor the set into one shared
  constant if possible.
- **Additive.** `chapter?` is optional; consumers that ignore it are unaffected — a plugin
  with no chaptered folders simply renders flat, exactly as today.

---

## Implementation (2026-07-10)

**Capture point chosen: the plugin generator (codegen), not the PPX.** The Approach
above leads with a spec-PPX capture but explicitly permits "*or the component-registration
codegen*" — the codegen path was taken because it is strictly cleaner here:

- **Single-sourced heuristic.** The generator already walks `src/` and already classifies
  folders via `ComponentKind.folderToKind` (the one kind-folder vocabulary). `chapterOf`
  reuses `ComponentKind.isKindFolder` directly, so there is *no* second copy of the
  kind-folder set (the PPX path would have had to duplicate it in OCaml and keep the two
  in sync — the exact "heuristic parity" risk this plan flagged).
- **No module-type threading.** Chapter flows as *data* (`~componentChapters`), so no
  `Spec` module type nor any hand-written spec implementer needs a new `let chapter`.
- **No PPX rebuild/republish** gate before CI passes.

### Data flow

1. **`Discovery.chapterOf(relPath)`** (`reventless-spec/src/generator/Discovery.res`) —
   first `src/`-relative directory segment that is not a kind-folder (`ComponentKind.isKindFolder`);
   `src/<Chapter>/<Kind>/<Component>.res` → `Some("<Chapter>")`, a component directly under a
   kind-folder → `None`. `Discovery.chaptersByStem` maps stems→chapter (sorted, deterministic).
2. **`Codegen.render`** filters that map to actual component stems (drops `_Behavior` /
   `_Projections` body files, tasks, extensions, EPs — none carry a chapter field) and emits
   `~componentChapters=Dict.fromArray([...])` into the generated `makePluginDefinition` call
   — **only when non-empty**, so a flat-`src/` plugin's `Plugin.res` stays byte-identical.
3. **`makePluginDefinition` / `Plugin_Structure.make`** (core + the `ReventlessInfra.Plugin` /
   `ReventlessCore` signatures) gained `~componentChapters: dict<string>=?`; each per-component
   def sets `chapter: componentChapters->Dict.get(Spec.name)` (`option<string>`).
4. **Spec records** (`reventless-spec/src/components/Plugin.res`) — `chapter:
   @s.matches(stringOptionSchema) option<string>` on `queryableDef` (read models + state-view
   slices), `writableDef` (aggregates + state-change slices), and the automation / inbound /
   outbound translation slice defs. Mirrors the existing `visibility` field (js_nullable,
   always-written → old persisted defs must be reset, per the alpha-wipe convention).
5. **Read model** round-trips automatically — `PluginsReadModelSpec` stores the whole
   `pluginStructure`, so the new nested field rides through the Sury schema unchanged.
6. **onPluginBuilt hook** (`Plugin_BuiltHook.pluginDeployedSchema` gained `chapter?: string`;
   `Plugin_Builder.construct` builds a `chapterByName` map from the in-scope `pluginStructure`
   and sets it on each component schema) — hook parity, single-sourced from the structure.
7. **`Platform_ComponentDefinitionsApi`** hand-rolled encoders emit `chapter` on the wire.

### What the examples now emit

Every example plugin uses the `src/<Chapter>/<Kind>/` layout, so regenerating their
committed `Plugin.res` added a `~componentChapters` line, e.g. catalog →
`[("Categories","Category"),("Category","Category"),("Product","Product"),("Products","Product"),…]`.

### Verification

- Full monorepo `pnpm run build` — exit 0, zero warnings; all six example `Plugin.res`
  regenerate and compile.
- New `reventless-spec/tests/DiscoveryTest.res` — `chapterOf` (chaptered vs kind-folder vs
  entity-subfolder vs src-root) and `chaptersByStem` (dedup + body-file inclusion + no-chapter
  exclusion). Spec suite: 92 passed.
- New `PluginStructureTest` "componentChapters threading" block — a chaptered SCS/SVS carries
  `Some(chapter)`, an unmapped one carries `None`, and no `~componentChapters` → all `None`.
  Core plugin/admin suites (`PluginStructureTest`, `ManifestVisibilityTest`,
  `Platform_ComponentDefinitionsApiTest`) and gwt graph suites
  (`DomainGraphTest`, `DomainDeadCodeTest`) all green.

### Not in scope (deliberate)

- **Extensions / extension points** carry no `chapter` — their `Spec.name` is dotted /
  plugin-qualified (not the filename stem), so the stem-keyed map wouldn't match; they render
  flat. The graph-node bands the plan targets (aggregates / views / slices) are covered.
- **Shared graph-derivation** (`DomainGraphD2 ~chapters` / `GraphOps.propagateChapters`) already
  supported chapter bands; the host that builds the `~chapters` seed lives in the external VS Code
  extension. This plan supplies the missing *deployed* datum it can now read — no renderer change.
