# Plugin `make` Derives Its Own Structure; Host-Shell Wiring Becomes a Toggle

**Status:** Analysis
**Date:** 2026-07-30
**Context:** The generated plugin composition root currently calls **two** builder
functions — `Platform.Plugin.makePluginDefinition(...)` and
`Platform.Plugin.make(...)` — with a large overlapping argument list. This analysis
asks whether `make` can derive the plugin structure itself from the parameters it
already receives, so the composition root supplies each component list once. It also
asks whether a platform can be built with or without a host shell (Auto UI), how that
is configured, and how the generator should decide what host-shell-specific code to
emit.

Related prior work: `docs/plans/done/harmonize-plugin-make-signature.md` (collapsed
`make` to zero-arg everywhere and moved the UI-bundle env read inline);
`docs/analysis/zero-touch-plugin-assembly.md` (auto-discovery of components — a
different concern). This analysis is the next step past the first.

---

## Part A — Fold `pluginStructure` derivation into `make`

### A.1 What the generator emits today

`reventless/spec/src/generator/Codegen.res` `renderComposition` emits, per plugin
(example: `examples/online-shop-aggregates/catalog/src/Plugin.res`):

```rescript
let pluginStructure = Platform.Plugin.makePluginDefinition(
  ~name="Catalog",
  ~aggregates=[module(CategoryAggregate), module(ProductAggregate), module(ProductDemandAggregate)],
  ~readModels=[module(CategoriesReadModel), module(ProductDemandsReadModel), module(ProductsReadModel)],
  ~extensions=[module(Orders_Extension)],
  ~extensionPoints=[module(Products_ExtensionPointMapping)],
  ~componentChapters=Dict.fromArray([...]),
)

let make = () =>
  Platform.Plugin.make(
    ~name="Catalog",
    ~heartbeatInterval=5,
    ~extensionPoints=[module(Products_ExtensionPoint)],
    ~extensions=[module(Orders_Extension)],
    ~aggregates=[module(CategoryAggregate), module(ProductAggregate), module(ProductDemandAggregate)],
    ~readModels=[module(CategoriesReadModel), module(ProductDemandsReadModel), module(ProductsReadModel)],
    ~tasks=[module(ImportProductsTask)],
    ~pluginStructure=pluginStructure,
    ~uiFragments=?uiBundleUrl->Option.map(url => Platform.Plugin.makeAutoUIManifest(...)),
  )
```

The two builder signatures live in `reventless/infra/src/components/Plugin.res:43-98`
(mirrored in `reventless/core/src/plugin/component/Plugin.res`). The component module
arrays are written out twice.

### A.2 Why it is split today — two distinct consumers of the structure

The `pluginStructure` value is used by two paths with very different cost profiles:

- **Deploy path.** The platform calls `P.make()` and reads the structure back off the
  built component's outputs — `outputs.pluginStructure`
  (`reventless/local/src/Platform.res:860,1045`;
  `buildPluginInScope(~makePlugin=P.make, ...)` at `1411,2152`). On this path the
  module-level `let pluginStructure` binding is **not read** at all; `construct`
  receives `~pluginStructure` and stores it into `Plugin.outputs.pluginStructure`
  (`Plugin_Builder.res:774,976`).

- **Cheap reflection path.** Capability emission and the domain-graph tooling read
  `Make(platform).pluginStructure` **without ever calling `make()`**:
  `reventless/local/src/EmitCapabilities.res:46`
  (`type builtPlugin = {"pluginStructure": ...}`) and
  `reventless/gwt/src/LocalHost.res:51`. They must avoid `make()` because `make`'s
  `construct` throws unless deploy hooks are set —
  `Plugin_Builder.res:114-131` (`"scheduler not set — call makePlatform/deployPlugin
  first"`, same for `api`/`apiRole`). `makePluginDefinition` → `Plugin_Structure.make`
  is pure metadata extraction with **no** hook dependency
  (`reventless/core/src/plugin/component/Plugin_Structure.res:160`).

So the split is not accidental: the standalone binding exists so tooling can reflect a
plugin's shape without provisioning infrastructure. **Any refactor must preserve a
hooks-free way to obtain the structure.** Folding derivation *only* inside `make`
(which provisions and requires hooks) would break capability emission and the domain
graph.

### A.3 The exact overlap

| Parameter | `make` | `makePluginDefinition` | Same type? |
|---|---|---|---|
| `name` | ✓ | ✓ | yes |
| `aggregates` | ✓ | ✓ | yes |
| `readModels` | ✓ | ✓ | yes |
| `stateChangeSlices` | ✓ | ✓ | yes |
| `stateViewSlices` | ✓ | ✓ | yes |
| `automationSlices` | ✓ | ✓ | yes |
| `outboundTranslationSlices` | ✓ | ✓ | yes |
| `inboundTranslationSlices` | ✓ | ✓ | yes |
| `extensions` | ✓ | ✓ | yes |
| `extensionPoints` | ✓ (`ExtensionPoint.T`) | ✓ (`ExtensionPointMapping.Mapping`) | **no** |
| `componentChapters` | — | ✓ | make lacks it |
| `heartbeatInterval`, `tasks`, `systemCallableComponents`, `componentRuntime`, `uiFragments`, `opts` | ✓ | — | structure doesn't need |

Nine parameters are byte-for-byte duplicated. Two wrinkles block a naive merge:

**Wrinkle 1 — extension points have two representations.** `make` takes the *built* EP
module (`ExtensionPoint.T`, which exposes only `name` —
`reventless/infra/src/components/ExtensionPoint.res:49-67`). Structure derivation reads
the raw *mapping* module (`M.ExtensionPoint.name`, `M.Delegate.eventSchema`,
`M.Delegate.name`, `M.ExtensionPoint.commandSchema` —
`Plugin_Structure.res:798-808`). A built EP cannot yield those today.

The mappings are, however, in scope inside the EP wrappers that produced the built
module — `Platform.ExtensionPoint.Make` / `Make2` / `Make3` / `MakeMulti`
(`reventless/local/src/Platform.res:576-644`) each already hold `Mapping.Delegate` and
`Mapping.ExtensionPoint`. So re-exposing that metadata is additive, not a redesign.

**Wrinkle 2 — `componentChapters` is only on `makePluginDefinition`.** If `make`
derives the structure, it must also accept `~componentChapters` (a plain
`dict<string>` from the generator's folder scan — `Codegen.res:421-430`).

### A.4 Design options

**Option 1 — `Platform.Plugin.define(...)` returns `{make, structure}` (recommended).**

Replace the two calls with one. `define` takes every component list **once**, derives
the structure eagerly and purely, and returns a record:

```rescript
type pluginDefinition<'component> = {
  structure: Reventless.Plugin.pluginStructure,   // pure, hooks-free — for reflection
  make: unit => 'component,                        // deferred — provisions on call
}
```

Generated composition root collapses to a single argument list; keep the existing
export field names so the reflection interop shape `{pluginStructure, make}` is
unchanged:

```rescript
let {structure: pluginStructure, make} = Platform.Plugin.define(
  ~name="Catalog",
  ~heartbeatInterval=5,
  ~aggregates=[module(CategoryAggregate), ...],
  ~readModels=[module(CategoriesReadModel), ...],
  ~extensionPoints=[module(Products_ExtensionPointMapping)],   // mappings — single source
  ~extensions=[module(Orders_Extension)],
  ~tasks=[module(ImportProductsTask)],
  ~componentChapters=Dict.fromArray([...]),
  ~uiBundleUrl?,                                                // see Part B
)
```

- `structure` derivation calls `Plugin_Structure.make` — no hooks, so
  `EmitCapabilities` / `LocalHost` keep reading `.pluginStructure` cheaply, exactly as
  today (they never touch `.make`).
- `make` is a thunk closing over the already-derived structure; on the deploy path it
  threads it into `construct` just like today's `~pluginStructure`, and every hook-gated
  operation stays deferred to call time.
- **Extension points unify to the mapping list.** `define` builds the EP components
  internally by calling the platform's EP builder. This requires threading
  `Platform.ExtensionPoint.Make{,2,3,MultiN}` (or an arity-dispatching helper) into the
  plugin builder — the one non-trivial piece. The arity grouping logic
  (`renderExtensionPoints` in `Codegen.res`) moves from the generator into that helper,
  or the generator passes pre-grouped `array<array<mapping>>`.

This is the design that literally matches the request: provide `make`'s inputs once;
`make`/`define` creates the structure because it now holds every parameter.

**Option 2 — shared `let` bindings, two calls (smaller change).**

Keep `makePluginDefinition` and `make`, but have the generator emit each component
array once as a `let` binding and reference it from both calls; drop `~pluginStructure`
from `make` (make derives internally when not supplied). This removes the *textual*
duplication without a new builder entry point and without touching the EP type gap
(each call keeps its own EP representation). It does not, however, unify the two EP
lists, and it still shows two builder calls in the generated file — a partial answer to
the request.

**Option 3 — extend `ExtensionPoint.T` with structure metadata; keep two params.**

Add `let structureMappings: array<epMappingMeta>` (plain data: delegate name, EP name,
source event schema, EP command schema) to `ExtensionPoint.T`, populated by the
`Make{,2,3}` wrappers that already hold the mappings. Then `make` can derive the full
structure from its existing `~extensionPoints` (built) param — no separate mapping
list, no EP-arity logic moving into core. This is the least invasive way to close
Wrinkle 1 and composes with Option 1 (if unifying EP construction proves too large,
`define` can still take built EPs and read `structureMappings` off them).

**Recommendation:** Option 1 (`define` returning `{structure, make}`), with the
component modules grouped into one `components` record (A.4a) and extension points
carrying their own mapping metadata (A.4b, the Q2 fix) so EPs are passed once like every
other component. `pluginStructure` is *derived from* that bundle, never an input to it
(A.4a). Option 3's additive `ExtensionPoint.T` field is the concrete mechanism for the EP
half and can land independently first, de-risking the rest.

### A.4a Can `pluginStructure` itself be `make`'s input? (No — and why it matters)

A tempting simplification is to invert the flow: pass only `pluginStructure` (plus
`name` / `heartbeatInterval`) and have `make` read every component detail out of it. This
is **not feasible**, and the reason clarifies the whole design.

Two different things are loosely called "structure":

1. **`Reventless.Plugin.pluginStructure`** — the record `makePluginDefinition` returns.
   It is *serialized metadata*: component schemas are JSON strings
   (`schema: v->SuryToJsonSchema.deriveObjectSchema->JSON.stringify`,
   `Plugin_Structure.res:279,355,643`), plus names, references, chapters, query fields.
   It is intentionally lossy and JSON-friendly so tooling can reflect a plugin without a
   platform (Part A.2).

2. **The live component modules** — `module(CategoryAggregate)` and friends, carrying
   behavior/handler functions, `commandSchema: S.t<unknown>` (a live sury schema, not a
   string), event mappings, and `moduleUrl` for runtime dynamic import.

`make`'s `construct` consumes **#2**: `createAggregatesWithoutEventMappers`,
`Dcb_Builder.Make`, `createReadModels`, `createTasks`, `createExtensionPoints` all iterate
the executable modules and their live `S.t` schemas
(`Plugin_Builder.res:142-170,356,873`, `629`). None of that is reconstructible from #1 —
a JSON-string schema and a metadata record do not yield back a command handler, a
projection function, or a `moduleUrl`. **`pluginStructure` is derived from the modules,
not a source that can drive them.**

The achievable version of the same instinct is to invert toward #2: pass the live
component modules as a **single bundle** and let `make` both build the infrastructure and
*derive* the serializable `pluginStructure` from that bundle. Concretely, group the
per-kind arrays into one `components` record:

```rescript
type components<'api, 'role> = {
  aggregates: array<module(ReventlessInfra.Aggregate.T with type api = 'api)>,
  readModels: array<module(ReventlessInfra.ReadModel.T with type api = 'api and type role = 'role)>,
  stateChangeSlices: array<module(ReventlessInfra.StateChangeSlice.T)>,
  stateViewSlices: array<module(ReventlessInfra.StateViewSlice.T)>,
  automationSlices: array<module(ReventlessInfra.AutomationSlice.T)>,
  outboundTranslationSlices: array<module(ReventlessInfra.OutboundTranslationSlice.T)>,
  inboundTranslationSlices: array<module(ReventlessInfra.InboundTranslationSlice.T)>,
  extensions: array<module(ReventlessInfra.Extension.Blueprint)>,
  extensionPoints: array<module(ReventlessInfra.ExtensionPoint.T)>,  // now carries its mapping (A.4b)
  tasks: array<module(ReventlessInfra.Task.T)>,
}
```

so the call collapses to roughly:

```rescript
let {structure: pluginStructure, make} = Platform.Plugin.define(
  ~name="Catalog",
  ~heartbeatInterval=5,
  ~components,
  ~componentChapters?,   // metadata-only; folder-derived by the generator
  ~uiBundleUrl?,          // Part B
)
```

The record still enumerates each kind — the arrays are heterogeneously typed (an
aggregate module and a slice module are different module types and cannot share one
array), so they cannot merge into a single list. What it buys is exactly the requested
surface: `make` takes `name`, `heartbeatInterval`, and one bundle, and derives everything
else — including `pluginStructure` — from it. `componentChapters` stays a separate small
argument because it is pure folder-layout metadata the modules do not carry.

### A.4b Extension points: the odd one out (Q2)

Every non-EP component is passed to `make` as a single built module, and the structure
derivation reads what it needs from that module's `.Spec` — e.g.
`A.Spec.commandSchema` / `A.Spec.name` (`Plugin_Structure.res:398,560`). The built
module carries its own metadata.

Extension points are the **only** component passed in two forms because the built
`ExtensionPoint.T` exposes only `name` (`ExtensionPoint.res:49-67`) and drops the
mapping the structure needs (`M.Delegate.eventSchema`, `M.Delegate.name`,
`M.ExtensionPoint.commandSchema` — `Plugin_Structure.res:798-808`). That single omission
is the entire reason a second raw-mapping parameter exists.

The consistent fix is to make the built EP carry its mapping metadata, exactly as an
aggregate carries its `.Spec` — then pass the EP **once**, like every other component.
The `Make` / `Make2` / `Make3` / `MakeMulti` wrappers already hold the mapping modules in
scope (`local/Platform.res:576-644`); they need only re-export a small
`structureMappings: array<epMappingMeta>` (plain data: delegate name, EP name, source
event schema, EP command schema). `Plugin_Structure.make` then reads EP metadata off the
built module instead of a separate `~extensionPoints` mapping list, and the two-forms
inconsistency is gone. This is additive and touches no EP-arity logic.

(The alternative — pass only the mapping and build the EP inside `define` — also yields a
single representation, but moves the arity dispatch into core. Re-exposing the mapping on
`ExtensionPoint.T` is the smaller, more consistent change and is the recommendation.)

### A.4c Component chapters: flip the map, and optionally a first-class `Chapter`

`componentChapters` is the last stringly-typed, duplicated blob in the generated
composition root:

```rescript
~componentChapters=Dict.fromArray([
  ("Categories", "Category"), ("Category", "Category"),
  ("Product", "Product"), ("ProductDemand", "ProductDemand"),
  ("ProductDemands", "ProductDemand"), ("Products", "Product"),
])
```

It is derived by the generator from source-folder layout
(`Discovery.chaptersByStem`, keyed by filename **stem**), threaded as `dict<string>`
(component name → chapter), and consumed as an *attribute* set on each component def:
`def.chapter: option<string>` (`Plugin_Structure.res:180,651,700,723,746`;
mirrored in the built-hook `Plugin_Builder.res:404-410`). Tests and the deployed admin
read model read `def.chapter` (`PluginStructureTest.res:659-674`;
`Platform_ComponentDefinitionsApiTest.res`), and per project memory the cross-repo event
graph reads it too. **That `def.chapter` output shape is the stable contract and should
not move.**

**Framing:** this literal is *generated*. The generator is the single source of truth,
so raw strings here are not a real typo risk — the "use real types to avoid typos"
motive is weak for generated artifacts and only becomes strong if composition roots
become hand-written (the zero-touch direction). The wins below are readability,
de-duplication, a latent-bug fix, and conceptual uniformity — not typo-safety per se.

**Tier 1 — flip + `dict{}` + `.Spec.name` (cheap; recommended now).**

Emit chapter → members, referencing each member's `.Spec.name` rather than a raw
string, with the idiomatic literal:

```rescript
~componentChapters=dict{
  "Category":     [Categories.Spec.name, Category.Spec.name],
  "Product":      [Products.Spec.name, Product.Spec.name],
  "ProductDemand":[ProductDemands.Spec.name, ProductDemand.Spec.name],
}
```

Consequences — all contained:

- The **output** `def.chapter` shape is unchanged; `Plugin_Structure.make` builds the
  reverse (name → chapter) index internally. **No consumer, wire, admin-read-model, or
  cross-repo impact.**
- Three internal spots change: `Discovery.chaptersByStem` → group-by-chapter; the
  generator emission (`Codegen.res:421-430`); and the `componentChapters` param type at
  its two consumption sites (`Plugin_Structure.res:180`, `Plugin_Builder.res:404-410`).
- **Fixes a latent bug.** Chapters are keyed by filename **stem**
  (`Discovery.chaptersByStem` uses `d.stem`) but looked up by **`Spec.name`**
  (`Plugin_Structure.chapterOf`). A component with an explicit `@@reventless.spec("X")`
  in a chapter folder has stem ≠ `Spec.name`, so today its chapter lookup silently
  misses. Emitting the member as `Module.Spec.name` makes key and lookup agree.
- `dict{}` is idiomatic ReScript v12 but is **not yet used anywhere in this repo** (0
  occurrences) — a new-but-fine convention.

**Tier 2 — a first-class `Chapter` component (bigger; conditional payoff).**

Model a chapter as a generator-synthesized module (or a `Chapter/` marker) exposing
`name` + `members`, folded into the `components` bundle (A.4a) and handled uniformly:
`construct` ignores it (it provisions nothing); `Plugin_Structure` still derives each
`def.chapter` from membership, preserving the output contract and cross-repo consumers.

- **Unlocks** what the flat dict cannot: explicit chapter **ordering** (today chapters
  sort by stem — `Discovery.res` ~line 50) and **nesting** (see below).
- **Costs** a new component kind plus generator (and likely PPX) support and tests. For
  generated code the gain is uniformity + ordering + nesting; typed chapter *names* only
  pay off under hand-written composition.
- **Hard constraint on "members as modules":** a chapter's members span multiple kinds
  (aggregate + read model) whose module types differ, so members cannot be one
  `array<module(...)>`. They remain `array<string>` via `.Spec.name` (typed at the
  extraction site) unless a minimal existential `module(HasSpecName)` wrapper is
  introduced — ceremony for little gain. So even a `Chapter` component lists members by
  `.Spec.name`.

**Nested chapters.** Today a chapter is exactly one folder level: `chapterOf` returns
the first path segment when it is not a kind-folder (`Discovery.res:33-44`). Nesting is
the generalization to *all leading non-kind segments*:
`src/Inventory/Products/Aggregate/Product.res` → chapter path `["Inventory", "Products"]`.

The typed tree cannot use recursive first-class modules — **ReScript/OCaml forbids a
module type from referencing itself**, so `children: array<module(Chapter)>` inside
`module type Chapter` will not compile. Encode nesting with **parent links** instead
(recursive *records* are still fine for the derived output):

```rescript
module type Chapter = {
  let name: string
  let parent: option<string>   // parent chapter, referenced as <Parent>.name
  let members: array<string>   // member components, referenced as <Spec>.name
  let sortOrder: int
}
```

Generated (from the nested folders, one module per chapter folder):

```rescript
module InventoryChapter: Reventless.Chapter = {
  let name = "Inventory"; let parent = None; let members = []; let sortOrder = 0
}
module ProductsChapter: Reventless.Chapter = {
  let name = "Products"; let parent = Some(InventoryChapter.name)
  let members = [Product.name, Products.name]; let sortOrder = 0
}
module CategoriesChapter: Reventless.Chapter = {
  let name = "Categories"; let parent = Some(InventoryChapter.name)
  let members = [Category.name, Categories.name]; let sortOrder = 1
}
// passed flat; parent links (not array order) define the tree:
~chapters=[module(InventoryChapter), module(ProductsChapter), module(CategoriesChapter)],
```

Every cross-reference is a module field (`InventoryChapter.name`, `Product.name`), so a
typo is a compile error. `Plugin_Structure.make` assembles the tree from `parent` and
emits a serializable recursive record on `pluginStructure`:

```rescript
type rec chapterNode = {
  name: string, members: array<string>, children: array<chapterNode>, sortOrder: int,
}
chapters: option<array<chapterNode>>,   // roots, ordered by sortOrder
```

Each component def keeps its existing `chapter: option<string>` set to the **leaf**
chapter name, so all current and cross-repo consumers are untouched; the nested
`chapters` tree is purely additive (optionally add `def.chapterPath:
option<array<string>>` for ancestry without a tree walk). Authoring stays zero-touch
(tree derived from folders); an optional `Chapter/<Name>.res` marker can annotate a
folder-derived node with `sortOrder` / `description` / `icon` — the payoff a folder name
alone cannot carry. A full walkthrough (folder tree → generated modules → `chapters`
output → consumer render) lives with this analysis's discussion notes.

**Opportunities of a first-class `Chapter` (ranked).** Promoting a chapter from a
derived `option<string>` attribute to a real component (own spec, discovered and
threaded like other kinds, surfaced as a `chapters` node in `pluginStructure`) turns "a
grouping label" into "a place to hang organizational intent." Ranked by value/effort:

1. **AutoUI presentation metadata (strongest).** A chapter is the natural home for the
   nav metadata the manifest already models one level down — `menuEntry` carries
   `label` / `icon` / `group` / `sortOrder` (`spec/src/components/Plugin.res:127-133`).
   A chapter node could carry a display `label` distinct from the folder name, plus
   `icon`, `description`, and explicit sibling order, so the host shell renders real
   section headers. Concrete, and reuses shapes that already exist.
2. **Group-level visibility & access.** Components already support
   `@@reventless.visibility(Public | Internal)` and manifest entries carry
   `requiredAccess`. A first-class chapter lets those be declared **once for a whole
   section** — `@@reventless.visibility(Internal)` hides the entire band from AutoUI; a
   coarse `requiredAccess` gates the nav area. Same caveat as everywhere: visibility is
   a UX hint, not a security boundary — real authorization stays per-component/command.
3. **Hierarchy & logical grouping.** Arbitrary-depth nesting (above), intra-chapter
   component order via `members` declaration order, and — for an explicitly authored
   chapter — groupings orthogonal to physical folder layout (a "Featured"/"Onboarding"
   cross-section). *Power-vs-simplicity:* orthogonal membership raises "can a component
   live in two chapters?"; defer unless needed.
4. **Domain narrative & tooling uniformity.** "Chapter" is Event Modeling vocabulary;
   first-classing it aligns framework structure with the methodology and gives one
   anchor that every reflection consumer already reads through `pluginStructure` — the
   event-graph and domain-graph (VSCode) views, the capability manifest, MCP tooling,
   and generated docs — with no new plumbing (versus today's scattered attribute).
5. **Validation.** A real component gives the generator a place to enforce integrity
   (every `member` resolves; no orphan members; no parent-link cycles; no duplicate
   chapter names) — mirroring the existing unique-spec-stem lint, and catching
   mis-grouping like the stem-vs-`Spec.name` miss noted in A.4c.

**Guardrail.** Keep a chapter **inert at deploy** — no infrastructure, no runtime, no
schema; it shapes `pluginStructure` and nothing else. "Handled like other components"
refers to discovery/threading, not to acquiring behavior (owning extension points,
carrying policy). Resisting that keeps the component model clean. Value concentrates in
opportunities 1–2 — concrete, folder-name-can't-express, reusing existing manifest
shapes; 3–4 come along for free once a chapter is a structure node.

**Recommendation:** Tier 1 now (contained readability + correctness win, zero
output-contract change). Reserve Tier 2 for when composition roots go hand-written or
chapters need explicit ordering/nesting, where a `Chapter` component composes naturally
with the `components` bundle.

### A.5 Generator changes (Codegen.res)

- Replace `renderPluginStructureCall` (`Codegen.res:340-434`, invoked `708-729`) and the
  `make` param assembly (`Codegen.res:758-796`) with a single `define` emission.
- EP emission (`renderExtensionPoints`, `renderEpMakeParam`) either stops building EP
  wrapper modules (Option 1 — pass mappings) or keeps them and passes both (Option 3).
- Drop the emitted `~pluginStructure=pluginStructure` param (`Codegen.res:777`); the
  structure comes back on the returned record.
- The `Aws` wrapper (`renderAwsWrapper`, `Codegen.res:576-590`) already just re-exports
  `Composition.make()`; if `define` returns a record, the wrapper re-exports both fields.

### A.6 Risk / migration

- `make`/`define` derivation must be pure (no scheduler/api/apiRole reads) so the
  reflection path stays hooks-free — verify against `Plugin_Structure.make`'s current
  hook-free property.
- Regenerate all example `Plugin.res` and the tracked AWS `Main.res`/`Plugin.res`
  (see CLAUDE.md `.res.mjs` tracking notes — the tracked deploy entry points must be
  re-emitted by the `examples/*/platform-aws` build steps).
- `ManifestVisibilityTest` and `PluginStructureTest` construct these calls directly —
  update to the new surface.

---

## Part B — Platform with or without a host shell (Auto UI)

### B.1 What is actually host-shell-specific in the generated code

The host shell is an external static SPA (default package
`@reventlessdev/reventless-host-shell`) that reads each connected plugin's
`pluginStructure` at boot and renders Auto UI — list/detail panels and pages — with no
plugin-side React (`Codegen.res:732-736`;
`packages/doc/docs-app/platform-and-plugin-guide.md:1622`).

Crucially, **`pluginStructure` is not host-shell-specific**. The same value feeds
capability emission, the domain graph, and MCP tooling (Part A.2). Auto UI works with
**no** per-plugin bundle: an unset `<PLUGIN>_UI_BUNDLE_URL` means "Auto UI renders every
fragment" (`Codegen.res:603-604`; `platform-and-plugin-guide.md:1658`). The only
host-shell-*specific* artifact the generator emits is the **federation-override**
block:

```rescript
@val external uiBundleUrl: option<string> = "process.env.CATALOG_UI_BUNDLE_URL"   // Codegen.res:606-609
...
~uiFragments=?uiBundleUrl->Option.map(url =>                                       // Codegen.res:742-756
  Platform.Plugin.makeAutoUIManifest(~remoteEntryUrl=url, ~pluginStructure, ...))
```

`makeAutoUIManifest` (`Plugin_Builder.res:996-1045`) derives `{remoteEntryUrl, panels,
pages}` purely from the structure; its output only *overrides* fragments a custom bundle
wants to take over. Manifest types: `Reventless.Plugin.uiFragmentManifest` /
`panelManifestEntry` / `pageManifestEntry` (`spec/src/components/Plugin.res:118-148`).

### B.2 Where the "host shell yes/no" decision already lives

It is **not** a generator decision and **not** a plugin.json key. It is a
`deployPlatform` argument:

- Both platforms declare `hostUiBundleConfig` and take `~hostUiBundle:
  option<hostUiBundleConfig>` — AWS `reventless/aws/src/Platform.res:1040-1090`, local
  `reventless/local/src/Platform.res:1930-1947`.
- **AWS** provisions the shell when `Some`: a CloudFront-fronted S3 SPA plus a generated
  `config.json` (apiEndpoint, region, Cognito ids, live-update endpoints) and optional
  `ui-hints.json`, exporting `hostShellUrl` (`aws/Platform.res:1716-1958`). When `None`,
  no shell site is deployed.
- **Local** *ignores* `~hostUiBundle` — the shell is served by an external `vite dev`
  against the in-process GraphQL server (`local/Platform.res:1926-1947`). The local
  platform starts only backend servers (`DomainGraphQL_Server`, `DomainMCP_Server` —
  `local/Platform.res:1918-1922`); it serves no HTML itself. "With UI" locally means
  additionally running that external dev server; "without" means not running it. The
  platform behaves identically either way.

`plugin.json` supports only `name`, `heartbeatInterval`, `exclude`, `runtime`
(`reventless/spec/src/generator/Config.res:15-106`) — no UI key.

### B.3 So what should the generator decide?

Because `pluginStructure` is shared infrastructure and Auto UI needs nothing per-plugin,
**the generator should keep emitting `pluginStructure` unconditionally** regardless of
whether a host shell is deployed. The only thing that is genuinely host-shell-adjacent —
and therefore the only thing worth gating — is the **federation-override plumbing**:
the `uiBundleUrl` env `external` and the `uiFragments`/`makeAutoUIManifest` argument.

Even that is currently harmless when no shell exists (an unset env var yields
`~uiFragments=?None`), so "generate for host shell or not" is really a question of
whether to emit *dead* override scaffolding, not whether Auto UI functions.

Given Part A, the cleanest formulation is: **`define` derives `uiFragments` internally**
from the structure plus a `~uiBundleUrl` argument, so the generated file never writes
`makeAutoUIManifest` by hand and never needs the `@val external`. Whether the override
door is open then reduces to whether `~uiBundleUrl` is threaded — a single boolean
decision.

### B.4 How to configure the decision

Three configuration surfaces, in increasing scope:

1. **Per-plugin, `plugin.json` `ui` key (new).** e.g. `"ui": false` suppresses the
   federation-override plumbing for a plugin that will never ship a custom bundle;
   default `true` keeps today's behavior. Read in `Config.res:read`, threaded through
   `Codegen`. Narrow blast radius; matches the existing per-plugin config channel.

2. **Platform-level "headless" build flag (`MakeWithConfig`).** Neither
   `MakeWithConfig` today carries a UI flag (AWS `aws/Platform.res:86+`; local
   `local/Platform.res:67-68`). A `headless` flag there would let a whole platform opt
   out of any UI-facing surface. But note this is a *deploy/runtime* concern, and the
   generator runs per-plugin before the platform is assembled, so a platform flag cannot
   reach per-plugin generation without a new config channel — this is a poorer fit for
   the generator question and better expressed as the existing `deployPlatform
   ~hostUiBundle` argument.

3. **Keep it env-gated (status quo).** Do nothing at generation time; `~hostUiBundle`
   on `deployPlatform` decides whether a shell exists, and `<PLUGIN>_UI_BUNDLE_URL`
   decides overrides. Simplest, but leaves the "dead scaffolding" the harmonize plan
   already flagged.

**Recommendation:** Keep `pluginStructure` unconditional. Fold `uiFragments` derivation
into `define` (removes the hand-written `makeAutoUIManifest` and the `@val external`).
Gate the *override door* with a `plugin.json` `ui` key (Option 1) defaulting to open, so
a headless plugin emits nothing UI-specific while Auto UI keeps working for everyone
else. The platform's actual host-shell presence stays where it correctly lives — the
`deployPlatform(~hostUiBundle)` argument — not in generation.

### B.5 Relationship between the two parts

The two axes converge on the same seam. Once `define` owns structure derivation
(Part A), it also owns everything Auto UI needs from a plugin, so `uiFragments` becomes
an internal derivation gated by one input rather than a second hand-written builder call.
Doing Part A first makes Part B a one-parameter follow-on.

---

## Summary

- **Feasible.** `make`/`define` can derive `pluginStructure` from the parameters it
  already receives. The load-bearing constraint is that a **hooks-free reflection path**
  must survive (capability emission + domain graph read the structure without
  provisioning); a `define(...) -> {structure, make}` record satisfies both consumers
  from one argument list.
- **`pluginStructure` cannot be `make`'s input.** It is serialized, lossy metadata
  (JSON-string schemas, no handlers, no `moduleUrl`) *derived from* the live component
  modules — not a source that can drive `construct`. The achievable version of "provide
  it once" is to pass the live component modules as a single `components` bundle and let
  `make` derive the metadata from it (A.4a).
- **Extension points are the one inconsistency.** They are the only component passed in
  two forms because the built `ExtensionPoint.T` drops its mapping. Make the built EP
  carry its mapping metadata (like an aggregate carries its `.Spec`) and pass it once —
  additive, no EP-arity change (A.4b).
- **Host shell:** whether a platform *has* a host shell is already a
  `deployPlatform(~hostUiBundle)` decision, not a generator one. The generator should
  keep emitting `pluginStructure` unconditionally (it is shared, non-UI infrastructure)
  and gate only the federation-override plumbing — ideally by folding `uiFragments`
  derivation into `define` and toggling it with a `plugin.json` `ui` key.
</content>
</invoke>
