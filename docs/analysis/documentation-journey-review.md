# Documentation Journey Review

**Date:** 2026-06-09
**Scope:** The Docusaurus site in `packages/doc/`, reviewed as three audience journeys that
start from the landing page (`src/pages/index.js`): **Evaluator**, **App developer**,
**Contributor**. The review walks each journey page-by-page and looks for duplication,
inconsistency, chattiness, stale content, journey-flow gaps, and diagram quality.

**Method:** Four parallel reviews (one per journey + a cross-cutting diagram audit), each
producing `file:line` findings, then a verification pass on the highest-impact and
conflicting claims. Corrections from that pass are folded in below.

---

## 0. The site map (for reference)

Five Docusaurus doc instances, each its own navbar tab:

| Route | Navbar label | Source dir | Audience role on landing page |
|---|---|---|---|
| `/app/` | **Intro** (index) + **App Guide** | `docs-app/` | Evaluator intro **and** app-dev reference (two roles, one tab) |
| `/tutorials/` | **Tutorial** | `docs-tutorials/` | Evaluator + app-dev runnable spine |
| `/infrastructure/` | **Infrastructure** | `docs-infrastructure/` | App-dev deploy + provider authors |
| `/framework/` | **Contributing** | `docs-framework/` | Contributor |
| `/blog` | Blog | `blog/` | — |

Landing-page journeys (`src/pages/index.js:50-78`):

- **Evaluator:** `/app/` → `/tutorials/get-started` → `/tutorials/hybrid-based`
- **App developer:** tutorial spine (`get-started`→`run-locally`→`test-locally`→`deploy-to-aws`→`test-on-aws`) → `/app/get-started` → `/infrastructure`
- **Contributor:** `/framework/get-started` → `/framework/internals/framework-internals` → `component-structure-pattern` → `extending-the-framework`

---

## 1. Top issues (ranked, cross-journey)

These are the highest-leverage fixes. Each appears in the per-journey detail below.

1. **Wrong package scope in the App Guide's first install step.**
   `docs-app/get-started.md:62,89,93` install `@reventless/reventless`,
   `@reventless/reventless-spec`, `@reventless/reventless-aws`. The real scope is
   `@reventlessdev/` (verified against `examples/online-shop-hybrid/catalog/package.json`),
   and there is **no `@reventless/reventless` package** at all. A developer copy-pasting
   this gets a 404. The same file's `rescript.json` block (`:75-79`) already uses
   `@reventlessdev/…`, so the page contradicts itself within 15 lines. **Verified.**

2. **Two contradictory contributor setup pages; the landing page links the broken one.**
   `docs-framework/get-started.md` uses `npm`, the old 3-package `packages/…` layout,
   `.res.js` (CommonJS), and `npx jest …res.js`. `docs-framework/contributing.md` uses
   `pnpm`, the real four-root layout, the mandatory `node scripts/workspace-setup.mjs`
   symlink step, and registry/token setup. Following `get-started.md`, `pnpm install`
   never even runs (the symlink step is missing). The landing page and
   `framework/index.md:72` point contributors at `get-started.md` — the wrong one.
   Retire/redirect it to `contributing.md`.

3. **`npm` vs `pnpm` drift across the whole site.** The tutorial spine and
   `contributing.md` are pnpm-correct (CLAUDE.md mandates pnpm 10). But
   `docs-app/get-started.md`, `docs-framework/get-started.md`, and
   `docs-framework/development-process.md` are entirely `npm`/`npx`, and the last two also
   show `.res.js`/CommonJS where the repo is `.res.mjs`/ESM. `development-process.md:289`
   even claims "CI uses `npm ci`" — CI uses pnpm with a frozen lockfile.

4. **Two event vocabularies for the same domain on consecutive pages.** The Product entity
   is `Update*`/`*Updated` in `docs-tutorials/get-started.md:36-39` and `aggregates.md`,
   but `Change*`/`*Changed` in `docs-tutorials/hybrid-based.md:54-57`, `dcb-slices.md`, and
   `plugin-system.md`. The evaluator's path (overview → hybrid) shows both back-to-back.
   This is the most damaging *consistency* bug because the example is the product demo —
   it reads as unmaintained. Pick one vocabulary and apply it across all four pages and the
   Extension-Point tables. (Note: `ProductPriceChanged` is the legitimate *public EP
   contract* event; the bug is using `*Changed` for *internal* slice events too, which
   muddies the "internal vs public are deliberately different" lesson.)

5. **Stale package model everywhere except `packages.mdx`, `contributing.md`, and
   `extending-the-framework.md`.** `framework/index.md:25-37` and `get-started.md:79-86`
   present a "3 packages under `packages/`" repo. The real monorepo is four roots:
   `reventless/` (framework, incl. `reventless-core`), `rescript/` (bindings), `examples/`,
   `packages/` (doc/ppx/vscode tooling). The framework core lives at
   `reventless/reventless-core/src/components/…`, not `packages/reventless/src/components/…`.
   `packages.mdx` already auto-generates the true list from each `package.json` — make the
   prose pages defer to it instead of restating a stale tree.

6. **The app developer's "Infrastructure entry" lands on provider-authoring docs.**
   `docs-infrastructure/index.md` is titled *"Providers"* and `get-started.md` is
   *"Scaffolding a Provider Package"* (`mkdir packages/reventless-myprovider`). An app dev
   arriving from `test-on-aws.md` wants "how do I deploy/operate on AWS," not "how to
   implement `EventLog_Adapter.Storage`." The tutorials promise `/infrastructure/aws/…`
   and `/infrastructure/custom-domain` — route the journey's infra entry to the AWS
   deploy guide, and keep provider-authoring as a clearly-labelled sub-track.

7. **`framework-internals.md` is internally duplicated and self-contradictory.** The page
   reads like two drafts concatenated: "Framework Architecture Patterns / Component
   Structure Pattern" appears at `:7-32` and again at `:34-66`. The first copy lists **5**
   component files (`:14-18`); the second calls it a "standardized **three-file** structure
   pattern" (`:44-48`). It also claims to be an "ordered" reading path but lists internals
   in two different orders, neither matching the sidebar. Merge into one numbered TOC that
   mirrors `sidebars-framework.js` and hands off explicitly to `extending-the-framework.md`.

8. **Reading-path / "who it's for" navigation is triplicated.** The three-persona split
   renders up to four times in the evaluator's first two clicks: landing "Pick your path"
   (`index.js:50-78`) ≈ `docs-app/index.md` "Who it's for" (`:44-48`) ≈ "Reading paths"
   (`:59-69`) ≈ "The documentation sections" (`:88-96`). Collapse to one canonical block;
   link to it from the others.

9. **The "comparison of approaches" table and the EP/Extension protocol deep-dive are
   each duplicated 3–4×.** The aggregate-vs-DCB comparison table appears in
   `docs-tutorials/get-started.md:283-291`, `choosing-an-approach.md:14-19`,
   `hybrid-based.md:430-434`, **and** `docs-app/aggregate-vs-dcb-decision-guide.md`. The
   Extension-Point/Extension protocol is fully re-explained in
   `docs-tutorials/get-started.md:224-277` and `docs-app/plugin-system.md:142-232`.
   Single-source each; the tutorial should link to the App Guide canonical home.

10. **Diagram convention violations: `projection-flow` mis-coloring.** The repo's own guide
    (`d2-diagrams.md:187-189`) reserves `projection-flow` for the *read-model/view-slice →
    QueryDb* hop and `event-flow` for *topic/log → collector/read-model*. Several journey
    diagrams color event-delivery hops as `projection-flow`:
    `aggregates.md:38`, `dcb-slices.md:40`, `messages.md:198`, `messages.md:226`,
    `concepts/dcb.md`. Worse, `aggregates.md` and `dcb-slices.md` then **omit the QueryDb
    node entirely**, so the real projection hop is never drawn.

---

## 2. Evaluator journey

Path: landing → `/app/` (Intro) → `/tutorials/get-started` → (`choosing-an-approach`) → `/tutorials/hybrid-based`.

**Overall:** the journey front-loads depth and back-loads payoff. The two heaviest pages
(`get-started` overview ≈ 320 lines of domain + EP-protocol spec; `hybrid-based` with full
ReScript `@schema` unions and DCB tag annotations) both sit *before* the evaluator runs
anything (`run-locally` is only reachable after the hybrid page). The genuinely
evaluator-shaped page, `choosing-an-approach.md`, is the shortest and best one — use it as
the model.

### Landing page (`src/pages/index.js`, `HomepageFeatures/index.js`)
- **Value prop stated 3× before scrolling:** hero (`index.js:21-27`), Layout meta
  (`index.js:111`), and the "Spec-Driven" card (`HomepageFeatures:9-16`) are near-verbatim.
  The 5-sentence hero (`:21-27`) restates the subtitle then pre-states the whole feature
  grid — cut to ~2 sentences.
- **"Try the example" CTA doesn't lead to an example** (`index.js:30-33`). It points at
  `/tutorials/get-started`, which is a conceptual overview, not a runnable example. The
  runnable step (`run-locally.md`) is two clicks deeper. Either re-point the CTA or rename it.
- **"Built on Effect" (`HomepageFeatures:71-75`) — needs nuance, not removal.** Verified:
  `@reventlessdev/rescript-effect` is a real workspace dependency of `reventless-core`, so
  the claim is defensible. But no downstream page mentions Effect, and readers will assume
  the TypeScript "Effect" library. Either substantiate it once in the Intro or drop the
  brand name and keep the concrete benefits ("typed errors, retries with backoff,
  streaming").
- **Homepage claims not honored on the next page:** "MCP APIs" (hero + Spec-Driven card)
  is absent from the Intro, which says only "a GraphQL API" (`docs-app/index.md:13,94`);
  "AI-Native" appears 3× on the homepage with no substantiating page on the evaluator path.
  Reconcile the headline claims with the first content page.

### Introduction (`docs-app/index.md`)
- **Says "where to go next" four times:** "Who it's for" (`:44-48`), "Three doorways"
  (`:51-57`), "Reading paths" (`:59-69`), "documentation sections" (`:88-96`) — same
  five destinations re-listed. Collapse to one.
- **Programming model stated twice on one page:** "in three sentences" (`:33-40`) and "How
  Reventless works" (`:71-86`) both define commands/events. Merge.
- **Branding split at the first click:** landing brands it "the spec-driven event
  **platform**" (`index.js:19`); Intro's first line says "an event-sourced CQRS
  **framework**" (`docs-app/index.md:9`). Pick one term.
- **No diagram** where it's needed most — the "programming model in three sentences" is
  begging for one small d2 flow (command → aggregate/DCB slice → event log → read model →
  GraphQL).

### Tutorial overview (`docs-tutorials/get-started.md`)
- **Too deep for an evaluator's 2nd click.** ~320 lines of per-entity command/event tables
  plus a full EP/Extension protocol spec (`:224-277`). Move the protocol depth and the
  approach-comparison tables to the App Guide; keep the overview to "domain + pick an
  approach → next."
- **"both implementations" / "three times" contradiction:** `:8` "two Plugins"; `:183`
  "implemented three times"; `:211` "both implementations share the same structural
  patterns" (there are three). Fix the counting.
- **DCB never expanded.** First use at `:105`/`:188` is unexpanded "DCB". Per the project
  terminology rule it must be "Dynamic Consistency Boundary" on first use; no tutorial page
  expands it.
- **"structurally impossible to import another plugin's internals" repeated 4–5×**
  (`:137,:205,:251,:273,:277`). Say it once.

### Choosing an approach (`docs-tutorials/choosing-an-approach.md`)
- **Best page in the journey** — short, clear table, per-entity decision procedure. Keep as
  the template. Its decision checklist (`:23-28`) is copied into `hybrid-based.md:440-446`;
  let this page own it and have hybrid link back.
- Would benefit from a small decision-tree diagram built from the existing prose checklist.

### Hybrid walkthrough (`docs-tutorials/hybrid-based.md`)
- **"Chapter:" headings are not a Reventless kind.** `### Chapter: Product` (`:48,:76,:191,
  :233`) sits next to real kinds `### Aggregate: Category` and `### Read Model:`. Readers
  will parse "Chapter" as a domain concept. Use the real kind (e.g. "DCB Entity: Product").
- **Refers to `CatalogEventLog` events (`:156`) right after arguing no such file exists**
  (the page's thesis at `:25-28,:114-121` is that the log is implied, with no
  `CatalogEventLog.res`). Contradiction.
- **CatalogProduct has three names for one concept:** slice `SyncCatalogProduct` (`:238`),
  events/commands `CatalogProductSynced`/`SyncNewProduct`/`SyncPriceChange` (`:239`), and EP
  table dispatching `SyncCatalogProduct` from `ProductBecameAvailable`/`ProductPriceChanged`
  (`:300-303`). Harmonize.
- **`@noApi` (`:204`) is not in the documented annotation vocabulary** (CLAUDE.md documents
  `@@reventless.visibility(Internal)`, `@noTag`, …). Verify it's real; if not, fix.
- **"identical to the … implementation" appears ~8×** (`:70,:156,:165,:214,:222,:289,:298,
  :309`). Say it once.
- **No diagram** despite being the deepest page; the command-routing story (aggregate
  commands → per-instance logs, DCB commands → shared log) is told in prose 3× and is the
  single best diagram candidate in the tutorials.

---

## 3. App developer journey

Path: tutorial spine → `/app/get-started` → write-side pages → `/infrastructure`.

**Overall:** the runnable spine (`run-locally` → `test-locally` → `deploy-to-aws` →
`test-on-aws`) is the strongest, tightest part of the whole site. The damage is at the
seams: the App Guide's `get-started.md` predates the spine (wrong scope, npm, 2021 dates),
and the infra entry points at provider-authoring docs.

### Tutorial spine
- `run-locally.md` — tight, runnable, best page in the set. Minor: the `dev:full` table
  (`:32-36`) says "two things side by side" but lists three rows (domain API, admin API,
  UI) — reword (two *processes*, three *endpoints*).
- `test-locally.md` — clean. `:44` asserts "the `AutoShipOrder` automation ships the order"
  as a guaranteed smoke-test effect; name the component the **hybrid** impl actually uses
  (the spine runs hybrid) or soften.
- `deploy-to-aws.md` — strong, well-scoped. **Stale host-shell pin:** `:84` shows
  `@reventlessdev/reventless-host-shell": "3.0.0-alpha.18"`; the real pin in
  `platform-aws/package.json` is `alpha.28` (**verified — 10 versions behind**). This is an
  exact pin the page itself tells readers to bump deliberately. **Token-prereq gap:** the
  GitHub Packages `read:packages` token (`:33-34`) is first actually needed at
  `pnpm install`, but the *local* tutorial never mentioned it — state where it first becomes
  necessary.
- `test-on-aws.md` — good. `:48` "exercises **Source B**" uses an undefined term (no
  Source A/B defined on prior pages). `:66-69` hand-editing a config block in
  `verify-subscriptions.mjs` papers over a tooling gap (could read `pulumi stack output`).
- **Correction to an earlier draft finding:** there are **no `sidebar_position` collisions**
  in the tutorials — `docs-tutorials/` has no `sidebar_position` frontmatter at all; order
  comes from the explicit array in `sidebars-tutorials.js`. (Verified; disregard any claim
  of a spine-ordering bug.)

### App Guide write-side pages
- `docs-app/get-started.md` — **the highest-impact page-level defect:** wrong package scope
  (#1 above), npm instead of pnpm, `date: 2021-11-22` frontmatter, a stale "Core-Stack /
  API-Stack" section (`:95-98`) using vocabulary replaced by **Platform**
  (`ReventlessAws.Platform.Make`), and a "Next Steps" (`:111-114`) that jumps to AWS deploy
  + unit tests, skipping the tutorial spine the journey is built around. This page reads as
  a standalone "init a project" recipe that predates the spine.
- `aggregates.md` — strong, good current d2 (`:22-41`). Inconsistencies vs siblings:
  composition root called `index.res` here (`:276`) but `Main.res` in `plugin-system.md`/
  `dcb-slices.md` (`Main.res` is correct); generator command shown as `pnpm run generate`
  (`:248`) but elsewhere it's the `prebuild`/`generate-plugin` flow (verify `pnpm run
  generate` exists); ReadModel shown with hand-written `config(~indexes=…)` (`:154-163`)
  while CLAUDE.md documents the `@index` field-annotation path — at least mention `@index`.
- `dcb-slices.md` — good, current d2. Event-naming drift (#4). Two different `Products.res`
  files exist across the write-side pages (read-model `Products` in `aggregates.md` vs
  view-slice `Products` here) with no disambiguation — collision risk a reader won't see.
- `plugin-system.md` — strongest reference page; the `Platform.T` builder table (`:57-70`)
  and two cross-plugin d2 diagrams (`:113-140`) are genuinely useful. Lists
  automation/translation-slice builders and `Plugin.make` params (`:236-251`) that have no
  worked example in the journey — link `mixed-source-automationslice.md` etc.
  **`heartbeatInterval` differs per page for the same Catalog plugin:** `60` in
  `aggregates.md:265,316`, `5` in `dcb-slices.md:233` and `plugin-system.md:84`. Pick one.
- `component-overview.md` — excellent diagram coverage (full aggregate + full DCB plugin
  d2). But it's ~760 lines and doubles as an abridged second component reference that
  overlaps `components/*.md`; trim the per-component prose to the two big diagrams + a table.
  `date: 2022-09-27`, no `sidebar_position`, several typos clustered in the EP/Extension
  prose ("sepcific" `:730`, "relagting"/"relating" `:719`, "everytime" `:692`). Diagram
  label `"audit logwebhook"` (`:215`) is garbled.

### Infrastructure entry
- `index.md` ("Providers") and `get-started.md` ("Scaffolding a Provider Package") are
  framework-extender docs, not app-dev deploy docs (#6). `get-started.md` also has stale
  mechanics: directs new packages to `packages/` (CLAUDE.md says provider packages go in
  `reventless/`); uses old `bs-dependencies` and `.res.js` (`:37,:44`) instead of
  `dependencies` + `.res.mjs`/`package-specs`; omits `@reventlessdev/reventless-ppx/bin`
  from `ppx-flags` and its required ordering; `@reventless/` scope again (`:50-66`).

---

## 4. Contributor journey

Path: `/framework/get-started` → `internals/framework-internals` → `component-structure-pattern` → `extending-the-framework`.

**Overall:** the *content* a contributor needs exists and is good in places
(`contributing.md`, `component-structure-pattern.md`, `extending-the-framework.md`), but the
*path the landing page sends them down* is the stale one. Fixing the entry point and the
duplicated/contradictory `framework-internals.md` would resolve most of the journey's pain.

### `framework/index.md`
- Stale repo tree and component paths (#5): everything under `packages/`; component example
  path `packages/reventless/src/components/EventLog/` should be
  `reventless/reventless-core/src/components/EventLog/`. Calls the package `reventless`
  (`:8`); it's `reventless-core`.
- "Where to Start" (`:70-75`) ends at `messages.md` and **never links
  `extending-the-framework.md`**, the page billed as the capstone.

### `framework/get-started.md` — retire/redirect (#2)
- npm throughout; `.res.js`/CommonJS (`:29`); `npx jest tests/MessageTest.res.js` (`:49`,
  should be `pnpm exec jest …res.mjs`); `cd packages/reventless` (`:42`, should be
  `reventless/reventless-core`); missing the mandatory `workspace-setup.mjs` symlink step
  and registry/token setup; stale model commit `update rescript to 11.1.4` (`:74`, repo is
  v12). Following this page, install fails.

### `contributing.md` — the accurate setup page, but buried
- Correct pnpm/corepack, four-root layout, `node scripts/workspace-setup.mjs`, registry
  note, frozen-lockfile rationale, zero-warnings grep. But it's filed under the "Dev
  environment" category (`sidebars-framework.js:56`), not the top-of-sidebar entry — a
  contributor following `index.md`/`get-started.md` may never reach it. Promote it (or
  redirect `get-started.md` here). Add a cross-link to `development-process.md` in "Further
  reading" (`:171-179`).

### `development-process.md` — accurate-ish but bloated and npm-based
- **Worst chattiness offender, 429 lines.** Cut the 22-bullet emoji "Do's/Don'ts"
  (`:253-274`) and the "Quick Reference" (`:397-429`, re-pastes the promotion sequence from
  `:137-187`); collapse the three near-identical alpha/beta/main promotion blocks into one
  parameterized note. Commit conventions are triple-covered here + `get-started.md` +
  `contributing.md` (+ CLAUDE.md) — this page is the canonical home; make the others 2-line
  pointers.
- npm/`.res.js` throughout (`:122-335`); `:289` "CI uses `npm ci`" is wrong (pnpm + frozen
  lockfile).

### `packages.mdx` — the right pattern
- Auto-generates the package list from each `package.json` at build time, so it can't go
  stale. Make `index.md`/`get-started.md`/`development-process.md` defer to it instead of
  hand-maintaining package tables.

### `internals/framework-internals.md` — duplicated + self-contradictory (#7)
- Doubled sections (`:7-32` then `:34-66`); "5 files" vs "three-file structure" on one page;
  claims to be "ordered" but lists internals in two different orders, neither matching the
  sidebar (`messages → serialization → resources → runtime → pulumi →
  component-structure-pattern → mcp → extending`) nor `extending-the-framework.md:9-12`
  (which also omits `mcp`). `date: 2021-11-22` (oldest in the set). Rewrite as one numbered
  TOC mirroring the sidebar, ending in an explicit handoff to `extending-the-framework.md`.
- **Onboarding gap:** the page opens at high abstraction (functors, first-class modules,
  `Pulumi.Output`) with no "smallest possible component" on-ramp; the first concrete worked
  example is in `component-structure-pattern.md` (the third internals page in sidebar order).
  Consider leading with the EventLog example.

### `internals/component-structure-pattern.md` — strongest internals page
- Concrete EventLog walkthrough + the journey's only well-placed internals d2 (`:210-234`).
  Single-sources the component-file list (which appears 4× across the journey — here,
  `index.md:41-51`, and twice in `framework-internals.md`). Says "2 required + up to 3
  optional" (`:15`) — make `framework-internals.md` agree. Stale source path
  `packages/reventless/src/components/EventLog/` (`:64`). Builder snippet (`:178-194`)
  references `eventTopicOps`/`storageOps` but destructures `storage`/`eventTopic` — the
  copy-paste example doesn't type-check. Typo "operationswith" (`:328`).
- The d2 at `:210-234` lacks the repo-mandated semantic classes on its nodes (see §5).

### `internals/extending-the-framework.md` — the model page
- Appropriately concise (84 lines), correct package names/paths, links resolve. Only nit:
  it asserts "the ordered path — messages, serialization, resources, runtime, pulumi, and
  the component-structure pattern" (`:9-12`), omitting `mcp` which sits right before it in
  the sidebar. Align the order claim across this page, `framework-internals.md`, and the
  sidebar — or soften it. The external links to `docs/analysis/*` design notes (`:57-59`)
  on a public docs site should get a maintainer's confirm-they're-public call.

---

## 5. Diagram audit

**Inventory:** 139 D2 blocks across 37 files + 1 Mermaid
(`docs-infrastructure/appsync-events-live-updates.md`). The framework is heavily
d2-diagrammed, with the notable exception of the tutorial pages (which use ASCII art) and a
few key journey pages that have **no diagram at all**: `docs-app/index.md`,
`docs-tutorials/hybrid-based.md`, `docs-framework/internals/framework-internals.md`,
`docs-infrastructure/index.md`.

**Currency vs real components:** good. Every component depicted still exists, and the newer
DCB/translation slices are covered in `component-overview.md`. Components with **no diagram
representation** anywhere in the journey/overview pages: **`StateTopic`** (only in the lone
Mermaid live-updates page, though it drives the whole live-update path), the **`Api`**
component (shown generically as "GraphQL API"), and the admin-layer **`Cloner`** /
event-graph / UI-fragment machinery.

**Convention violations (against the repo's own `d2-diagrams.md`):**
1. **`projection-flow` mis-coloring of event-delivery hops** — the most common error
   (#10): `aggregates.md:38`, `dcb-slices.md:40`, `messages.md:198`, `messages.md:226`,
   `concepts/dcb.md`. Reserve `projection-flow` for read-model/view-slice → QueryDb; use
   `event-flow` for topic/log → read-model/view-slice. `aggregates.md` and `dcb-slices.md`
   also omit the QueryDb node, so the real projection hop is never shown.
2. **DcbEventLog mis-classed as a normal EventLog:** `component-overview.md:305` and `:327`
   use `class: event-log` for `DcbEventLog`; the dedicated `dcb-event-log` class exists and
   is used correctly at `:439`. As-is, the StateChange/StateView mini-diagrams visually
   contradict the page's "shared DcbEventLog" narrative.
3. **`internals/runtime.md` is the least compliant file:** Lambda/strategy/builder nodes
   carry no class (`:73-227`, render as plain gray); `\n` line breaks are unquoted
   (`:164-167`, e.g. `L4: CommandTopic\nLambda` renders the `\n` literally — should be
   `"CommandTopic\nLambda"`); and the sequence-diagram actors (`:253-269`) have no class,
   violating the explicit "sequence actors MUST have classes" rule.
4. **`component-structure-pattern.md:210-234`** — nodes lack semantic classes.
5. **Garbled label** `"audit logwebhook"` at `component-overview.md:215`.

**Top diagram improvements:**
1. Fix the `projection-flow`/`event-flow` semantics across the five files above and add the
   missing QueryDb projection hop in `aggregates.md`/`dcb-slices.md`.
2. Fix the DcbEventLog class at `component-overview.md:305,327`.
3. Class the `runtime.md` sequence actors + strategy boxes and quote its `\n` labels.
4. **Convert tutorial ASCII art to d2** (`docs-tutorials/get-started.md` flows;
   `hybrid-based.md` command-routing) using the existing `cross-plugin`/`plugin-area`/
   flow classes — the tutorials are the only major section out of step with the site's
   d2-everywhere style, and the heaviest concept pages (Intro programming model, hybrid
   routing) have no visual at all.
5. Add **StateTopic** to one architecture overview so the live-update path
   (QueryDb stream → StateTopic Lambda → AppSync Events) is discoverable from the main
   journey, not only the standalone Mermaid page.

---

## 6. Consolidated "shorten / de-chatty" list

- Landing hero description → 2 sentences (`index.js:21-27`).
- `docs-app/index.md` → one navigation block instead of four; merge the two programming-model
  sections.
- `docs-tutorials/get-started.md` → move EP-protocol spec + comparison tables out; this page
  should be a 1-screen domain summary + "pick an approach."
- `hybrid-based.md` → drop the repeated "identical to…" tabulations; one statement of the
  shared-structure point.
- `development-process.md` → cut Do's/Don'ts (`:253-274`) and Quick Reference (`:397-429`);
  collapse the three promotion blocks.
- `component-overview.md` → trim per-component prose; keep the two whole-plugin diagrams + a
  table, defer detail to `components/*.md`.
- Single-source the duplicated artifacts: persona reading-path (1×), aggregate-vs-DCB
  comparison table (1×, in `aggregate-vs-dcb-decision-guide.md`), EP/Extension protocol (1×,
  in `plugin-system.md`), component-file-structure list (1×, in
  `component-structure-pattern.md`), commit conventions (1×, in `development-process.md`).

---

## 7. Verification notes (claims checked against source)

- ✅ Package scope bug in `docs-app/get-started.md` — confirmed (`@reventless/` vs real
  `@reventlessdev/`; no `@reventless/reventless` package).
- ✅ Host-shell pin stale (`alpha.18` doc vs `alpha.28` real) — confirmed.
- ✅ `@reventlessdev/rescript-effect` is a real `reventless-core` dependency — "Built on
  Effect" is defensible (needs nuance, not deletion).
- ✅ `docs-framework/internals/framework-internals.md` **exists** (an earlier draft finding
  claimed it didn't — that was wrong; the file is present and is the duplicated/contradictory
  page described in §4).
- ✅ Tutorial **`sidebar_position` collisions do not exist** — `docs-tutorials/` uses the
  explicit array in `sidebars-tutorials.js`; disregard any claim of a spine-ordering bug.
- ⚠️ Unverified (flagged for the editor): existence of `pnpm run generate` (`aggregates.md:248`),
  the `@noApi` annotation (`hybrid-based.md:204`), and whether `/infrastructure/aws/*` /
  `/infrastructure/custom-domain` routes referenced by the tutorials resolve.

---

# Addendum — Hands-on verification (2026-06-09)

**Method:** actually executed the runnable steps of the tutorial spine and app get-started
against the repo (`examples/online-shop-hybrid/platform-local`), introspected the live GraphQL
schema, and checked every file/script/config the AWS-path pages reference. This goes beyond the
read-only review above — several findings are bugs that only surface when you *run* the steps.

**What works:** `pnpm run build` compiles the local platform (150 modules); the backend boots
(reaches `startServers`, binds the platform API on 4001); the documented CQRS loop works once
the field names are corrected (verified a real `Catalog_Category_Add` mutation + `Catalog_Categories`
read round-trip). All AWS-path file/dir/script references resolve.

## Confirmed bugs — `docs-tutorials/run-locally.md`

- **HV-1 (backend default is SQLite, not in-memory).** `serve`, `dev`, and `dev:full` default to
  `REVENTLESS_LOCAL_BACKEND=sqlite:./.reventless/local.db` (a `local.db` file is created and
  **persists** across restarts). Memory is opt-in via `serve:memory` / `dev:full:memory`. The page
  contradicts this twice: line 10 "backed by in-memory stores" and line 76 "By default the local
  platform starts empty every run" with persistence framed as optional. It's backwards — persistence
  is the default; ephemeral is the opt-in. (`test-locally.md:75` "all on in-memory infrastructure"
  has the same error.)
- **HV-2 (wrong env-var names).** The page's table lists `PORT` and `ADMIN_PORT`. The platform
  actually reads `REVENTLESS_DOMAIN_PORT` (default 4000) and `REVENTLESS_PLATFORM_PORT` (default
  4001), plus `REVENTLESS_DOMAIN_MCP_PORT` (3001) and `REVENTLESS_PLATFORM_MCP_PORT` (3002) —
  see `reventless/reventless-local/src/Platform.res:702-705`. `GRAPHQL_DEBUG`/`MCP_DEBUG` are correct.
- **HV-3 ("two processes" is three).** `dev:full` runs `concurrently --names rs,backend,ui` — three
  processes (`rs` = `pnpm -w run watch` rescript watcher, `backend` = `serve:watch`, `ui`). The page
  (line 33, including the earlier cleanup edit) says "two processes". The UI also waits on `tcp:4001`,
  not the domain port.
- **HV-4 (minor, terminology).** Port 4001 is the **platform** API in code (`platformPort`); the page
  calls it "admin API". Defensible (it serves `Admin_*`) but drifts from the code's term.

## Confirmed bugs — `docs-tutorials/test-locally.md`

- **HV-5 (login table is wrong).** The page lists `admin/alice/bob/carol`. The committed seed
  template `examples/online-shop-hybrid/platform-local/users.example.yaml` defines only **`admin`/`admin`**
  (groups `Admin, User`) and **`user`/`user`** (group `User`). `alice`, `bob`, and `carol` do not exist.
- **HV-6 (link target is gitignored).** The page links to `platform-local/.reventless/users.yaml`,
  which is gitignored (repo `.gitignore: .reventless/`) — the GitHub link 404s. It should link to the
  committed `users.example.yaml`, and mention that `scripts/setup.mjs` (or
  `cp users.example.yaml .reventless/users.yaml`) seeds the real file.
- **HV-7 (GraphQL examples don't run — verified against the live schema).** Both snippets fail with
  `GRAPHQL_VALIDATION_FAILED`. Operations are **plugin-prefixed**, command mutations return the
  `CommandResult` **union** (need a selection set), and read queries return Relay **connections**:
  - Mutation: `Category_AddCategory(id, name)` → **`Catalog_Category_Add(id: "books", name: "Books") { __typename }`**
    (verified → `{"__typename":"CommandAccepted"}`).
  - Query: `Categories { id name }` → **`Catalog_Categories { edges { node { id name } } }`**
    (verified → returns the added category).
  - (For DCB-slice commands the shape is `Catalog_AddProduct(...) { __typename }` — no `Category_` infix.)
- **HV-8 (minor).** `X-User: admin` works but is **not required** for reads — without it the platform
  falls back to `defaultUser` and the query still returns data. Fine, but the example implies the header
  is load-bearing.

## AWS path — `deploy-to-aws.md` / `test-on-aws.md` (reference-checked, not executed)

- All references resolve: `platform-aws/`, `catalog-aws/`, `ordering-aws/` each with
  `Pulumi.{alpha,beta,main,yaml}`; `catalog-aws/Pulumi.alpha.yaml` carries the
  `platform:stack: reventless/...` line the page tells you to repoint; `platform-aws/verify-subscriptions.mjs`
  exists with the hardcoded host config block the page says to edit.
- **Note:** "Source B" (test-on-aws) *is* defined — in `verify-subscriptions.mjs`'s header (Source A/B).
  The earlier cleanup reworded it to "the live-update path", which is clearer for a doc reader; no further
  action needed.
- Not executed (needs an AWS account + Pulumi org); correctness of the deploy sequence itself is unverified.

## App Guide — `docs-app/get-started.md` (recipe checked, not run end-to-end)

- `generate-plugin` is a real bin (`reventless/reventless-spec/package.json` → `./run-generator.mjs`),
  so the `"generate": "generate-plugin src/"` + `prebuild` scripts are valid.
- Package scope/names, `rescript.json` `suffix: ".res.mjs"`, and the `reventless-ppx` → `sury-ppx` flag
  order all match the working `catalog` example. The recipe is internally consistent; a true fresh-project
  run (outside the monorepo, installing from the registry) was not performed.

## Severity

HV-1, HV-5, HV-7 are user-blocking on the evaluator/app-dev happy path (a copy-pasted login or curl
fails). HV-2, HV-3, HV-6 mislead but don't hard-block. HV-4, HV-8 are minor. Fixes are tracked in
`docs/plans/tutorial-handson-fixes.md`.
