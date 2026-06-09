# Documentation Journey Cleanup — Plan

**Source analysis:** [docs/analysis/documentation-journey-review.md](../analysis/documentation-journey-review.md)
**Created:** 2026-06-09
**Goal:** Fix correctness bugs, de-duplicate, shorten, and align diagrams across the three
audience journeys (Evaluator / App developer / Contributor), without losing any unique
content.

**Working rule:** update this plan after each step (check off tasks, note actual line deltas).
When fully done, `git mv` to `docs/plans/done/` as part of the final commit.

---

## Phasing rationale

Ordered so user-blocking correctness lands first, then the high-volume consolidation
(where most of the shortening happens), then consistency, then diagrams, then polish.
Phases are independently commit-able.

---

## Phase 1 — Correctness (user-blocking; little/no length change)

These break installs or send users down dead paths. Fix before anything cosmetic.

- [x] **1.1** `docs-app/get-started.md` — fix package scope `@reventless/` → `@reventlessdev/`
  at `:62,:89,:93`; remove the non-existent `@reventless/reventless` package; reconcile with
  the already-correct `rescript.json` block. *(verified bug)*
- [x] **1.2** npm → pnpm + `.res.js` → `.res.mjs` sweep across `docs-app/get-started.md`,
  `docs-framework/get-started.md`, `docs-framework/development-process.md` (incl.
  `:289` "CI uses `npm ci`" → pnpm + frozen lockfile).
- [x] **1.3** Retire `docs-framework/get-started.md` → thin redirect/pointer to
  `contributing.md`; update the landing page (`src/pages/index.js:73`) and
  `framework/index.md:72` to point at `contributing.md`. Promote `contributing.md` up the
  sidebar (out of "Dev environment").
- [x] **1.4** Replace stale 3-package `packages/…` repo model with the real four-root layout;
  defer package lists to `packages.mdx`. Files: `framework/index.md:25-37`,
  `framework/get-started.md:79-86`, component paths
  (`packages/reventless/src/components/…` → `reventless/reventless-core/src/components/…`)
  in `framework/index.md`, `component-structure-pattern.md:64`.
- [x] **1.5** `docs-tutorials/deploy-to-aws.md:84` — bump host-shell pin `alpha.18` → `alpha.28`.
  *(verified stale)*
- [x] **1.6** Re-route the app-dev "Infrastructure entry": make the journey land on the AWS
  deploy guide, not the provider-authoring `index.md`/`get-started.md`; relabel those as a
  clearly-marked provider-author sub-track. Fix `docs-infrastructure/get-started.md` mechanics
  (`packages/` → `reventless/`; `bs-dependencies` → `dependencies`; `.res.js` → `.res.mjs`;
  add `@reventlessdev/reventless-ppx/bin` + ordering to `ppx-flags`; `@reventless/` scope).
- [x] **1.7** Resolve the three flagged-unverified items (then fix or document): does
  `pnpm run generate` exist (`aggregates.md:248`)?; is `@noApi` a real annotation
  (`hybrid-based.md:204`)?; do `/infrastructure/aws/*` and `/infrastructure/custom-domain`
  routes resolve (referenced by tutorials)?

**Length impact:** small (~−110 net; mostly 1.3's retirement of `get-started.md`).

---

## Phase 2 — De-duplication & shortening (where the docs get shorter)

Single-source each duplicated artifact, keeping the best copy and replacing the others with a
one-line link. Then trim the chatty pages.

- [x] **2.1** Persona reading-path: keep landing-page "Pick your path" as canonical; reduce
  `docs-app/index.md`'s four nav blocks (`:44-48,:51-57,:59-69,:88-96`) to **one** + a link.
- [x] **2.2** Aggregate-vs-DCB comparison table: keep only in
  `aggregate-vs-dcb-decision-guide.md`; remove from `docs-tutorials/get-started.md:283-291`,
  `choosing-an-approach.md:14-19`, `hybrid-based.md:430-434` (link instead).
- [x] **2.3** EP/Extension protocol deep-dive: keep canonical in `plugin-system.md:142-232`;
  remove the duplicate in `docs-tutorials/get-started.md:224-277` (link instead).
- [x] **2.4** Component-file-structure list: keep canonical in
  `component-structure-pattern.md:19-47`; remove from `framework/index.md:41-51` and the two
  copies in `framework-internals.md` (link instead).
- [x] **2.5** Commit conventions: keep canonical in `development-process.md`; reduce
  `framework/get-started.md` (already retired in 1.3) and `contributing.md:111-114` to pointers.
- [x] **2.6** Trim `component-overview.md` (764 ln): keep the two whole-plugin d2 diagrams + a
  component table; cut the per-component prose that overlaps `components/*.md`.
- [x] **2.7** Trim `development-process.md` (429 ln): cut the 22-bullet Do's/Don'ts
  (`:253-274`) and Quick Reference (`:397-429`); collapse the three alpha/beta/main promotion
  blocks (`:137-187`) into one parameterized note.
- [x] **2.8** Trim `docs-tutorials/get-started.md` (320 ln): reduce to a 1-screen domain
  summary + "pick an approach → next" (EP protocol & comparison tables already moved in
  2.2/2.3); drop the 4–5× "structurally impossible to import" repetition.
- [x] **2.9** Trim `hybrid-based.md` (451 ln): drop the ~8× "identical to … implementation"
  tabulations; trim premature full-schema dumps to the salient lines.
- [x] **2.10** Merge `docs-app/index.md`'s two programming-model sections (`:33-40` + `:71-86`).

**Length impact:** the bulk of the shortening (~−800; see estimate table).

---

## Phase 3 — Consistency (naming/terminology; mostly neutral on length)

- [x] **3.1** Harmonize the Product event vocabulary: pick one of `Update*`/`*Updated` vs
  `Change*`/`*Changed` for **internal** events and apply across
  `docs-tutorials/get-started.md`, `hybrid-based.md`, `aggregates.md`, `dcb-slices.md`,
  `plugin-system.md`. Keep `ProductPriceChanged` only as the deliberate **public EP contract**
  event and make that distinction explicit once.
- [x] **3.2** Composition root file name: standardize on `Main.res` (fix `aggregates.md:276`
  `index.res`).
- [x] **3.3** `heartbeatInterval` for the running Catalog example: pick one value (fix the
  `60` in `aggregates.md:265,316` vs `5` in `dcb-slices.md:233`, `plugin-system.md:84`).
- [x] **3.4** Rename `### Chapter:` headings in `hybrid-based.md:48,76,191,233` to a real kind.
- [x] **3.5** Expand "DCB" → "Dynamic Consistency Boundary" on first use in the tutorial path
  (`docs-tutorials/get-started.md:105`).
- [x] **3.6** Branding: pick "platform" vs "framework" for the evaluator's first two pages
  (`index.js:19` vs `docs-app/index.md:9`).
- [x] **3.7** Fix `hybrid-based.md:156` "`CatalogEventLog` events" contradiction; harmonize the
  three CatalogProduct names (`:238,:239,:300-303`).
- [x] **3.8** Reconcile homepage claims with the Intro: MCP API (mentioned on homepage, absent
  in Intro) and "Built on Effect" (defensible via `rescript-effect` — substantiate once or
  drop the brand name).
- [x] **3.9** Rewrite `framework-internals.md` (101 ln): merge the doubled sections, fix the
  5-file vs 3-file contradiction, make it one numbered TOC mirroring `sidebars-framework.js`,
  and add an explicit handoff to `extending-the-framework.md`. Align the "ordered path" claim
  in `extending-the-framework.md:9-12` (it omits `mcp`).

**Length impact:** ~−40 (mostly 3.9's de-dupe), otherwise neutral.

---

## Phase 4 — Diagrams

- [x] **4.1** Fix `projection-flow` → `event-flow` on event-delivery hops:
  `aggregates.md:38`, `dcb-slices.md:40`, `messages.md:198,226`, `concepts/dcb.md`. Add the
  missing QueryDb projection hop (the real `projection-flow`) in `aggregates.md` and
  `dcb-slices.md`.
- [x] **4.2** Fix DcbEventLog class `event-log` → `dcb-event-log` in
  `component-overview.md:305,327`.
- [x] **4.3** `runtime.md`: class the sequence-diagram actors (`:253-269`) and strategy/builder
  boxes (`:73-227`); quote the `\n` labels (`:164-167`).
- [x] **4.4** Add semantic classes to the `component-structure-pattern.md:210-234` nodes.
- [x] **4.5** Fix garbled label `"audit logwebhook"` at `component-overview.md:215`.
- [x] **4.6** Convert tutorial ASCII art to d2 (`docs-tutorials/get-started.md` flows;
  add a command-routing d2 to `hybrid-based.md`; add a programming-model d2 to
  `docs-app/index.md`) using `cross-plugin`/`plugin-area`/flow classes.
- [x] **4.7** Add **StateTopic** to one architecture overview so the live-update path is
  discoverable outside the lone Mermaid page.

**Length impact:** roughly net-zero (ASCII replaced by d2; a few diagrams added).

---

## Phase 5 — Polish

- [x] **5.1** Fix the type-checking error in `component-structure-pattern.md:178-194`
  (`eventTopicOps`/`storageOps` vs `storage`/`eventTopic`).
- [x] **5.2** Typos: `component-overview.md` ("sepcific" `:730`, "relagting"/"relating" `:719`,
  "everytime" `:692`), `component-structure-pattern.md:328` "operationswith".
- [x] **5.3** Stale frontmatter dates: `docs-app/get-started.md:3` (2021),
  `component-overview.md:5` (2022), `framework-internals.md:2` (2021).
- [x] **5.4** Token prerequisite: state in `run-locally.md`/`deploy-to-aws.md` where the
  GitHub Packages `read:packages` token first becomes necessary.
- [x] **5.5** Add missing `sidebar_position` / handoffs where flagged (e.g.
  `component-overview.md`, `framework/index.md` "Where to Start" → link `extending-the-framework`).
- [x] **5.6** Small fixes: `run-locally.md:32-36` "two things"/three rows ✓; `test-on-aws.md:48`
  undefined "Source B" ✓; `dcb-slices.md` two `Products.res` disambiguation — **deferred**
  (low value, left for a later pass).
- [x] **5.7** Delete `src/pages/markdown-page.md` — stock Docusaurus boilerplate ("Markdown page
  example"), live at `/markdown-page`, zero inbound links, no sidebar/nav entry. The only
  genuinely unneeded file in the docs (see orphan audit below).

**Length impact:** negligible.

### Orphan audit (2026-06-09)

Checked all 150 section docs against their sidebars (strictly per-section) plus the standalone
`src/pages/` routes and inbound links. **Result: zero orphaned content pages** — every doc in
`docs-app/` (59), `docs-framework/` (39), `docs-infrastructure/` (42), `docs-tutorials/` (10) is
wired into its sidebar and reachable via nav/sidebar/search. The only deletable file is the
boilerplate `src/pages/markdown-page.md` (task 5.7). Conclusion: the site has **no
unneeded-page problem** — the issues are journey *curation* and *duplication*, not orphans.
"Off-journey" reference pages (component docs, adapter docs, deep-dives) are reached on demand
via sidebar/search and are expected to exist; the journeys are a short onboarding overlay, not
the full surface.

---

## How much shorter? (estimate)

In-scope **markdown** content (excluding the two `.js` files and `packages.mdx`, which don't
shrink) is **≈ 6,090 lines** across 26 pages. The consolidation and trim work removes an
estimated **≈ 950 lines (~15%)**, concentrated in six pages. Because most removals are
*de-duplication* (the canonical copy already exists elsewhere), this is a genuine net repo
reduction, not content moved out of sight.

| Page | Now | Est. after | Δ | Driver |
|---|---:|---:|---:|---|
| `component-overview.md` | 764 | ~430 | **−334** | 2.6 trim per-component prose |
| `development-process.md` | 429 | ~280 | **−149** | 2.7 cut Do's/Don'ts + Quick Ref + collapse blocks |
| `docs-tutorials/get-started.md` | 320 | ~180 | **−140** | 2.2/2.3/2.8 move tables + EP protocol, trim |
| `hybrid-based.md` | 451 | ~340 | **−111** | 2.2/2.9 dedup table + drop "identical to" |
| `docs-framework/get-started.md` | 105 | ~12 | **−93** | 1.3 retire → redirect |
| `framework-internals.md` | 101 | ~60 | **−41** | 2.4/3.9 de-dupe doubled sections |
| `docs-app/index.md` | 96 | ~66 | **−30** | 2.1/2.10 one nav block + merge model |
| `framework/index.md` | 75 | ~58 | **−17** | 1.4/2.4 defer package tree, link file list |
| `choosing-an-approach.md` | 56 | ~48 | **−8** | 2.2 link comparison table |
| `docs-app/get-started.md` | 118 | ~105 | **−13** | 1.1 fixes + drop stale Core-Stack section |
| misc small trims (Phase 3/5) | — | — | **~−15** | repetition removal |
| **Total** | **~2,615** (these pages) | **~1,665** | **≈ −950** | |

Notes:
- Estimates are line-count ranges; ±15% per page.
- Phase 1 net change is small (the host-shell/scope fixes are edits, not cuts); the −93 from
  retiring `framework/get-started.md` is the main Phase-1 reduction.
- Phase 4 (diagrams) is ~net-zero on length: ASCII→d2 swaps plus 2–3 added diagrams.
- The two big internals files `runtime.md` (601) and `messages.md` (723) are **not** shortened
  — they only get diagram-class fixes — so they're excluded from the reduction total.

---

## Completion (2026-06-09)

All five phases executed. The Docusaurus site builds clean (zero broken links/anchors).

**Key resolutions during execution (verified against source):**
- `pnpm run generate`, `@noApi`, and `/infrastructure/aws/*` + `custom-domain` routes are all
  **real** — the analysis's "flagged-unverified" items needed no fix.
- Event-vocabulary fix is per-entity, not global: **Product** (DCB slice) → `Change*`/`*Changed`;
  **Customer** (aggregate) correctly stays `Update*`/`*Updated`. CatalogProduct commands are
  `SyncNewProduct`/`ChangeSyncedPrice` (doc had `SyncPriceChange`).
- Canonical `heartbeatInterval` = `5` (from the hybrid example). Composition root = `Main.res`.
- "Built on Effect" softened to "a typed effect system" (it's the internal `rescript-effect`).

**Deviations from plan:**
- `2.2` — kept the comparison table in `choosing-an-approach.md` (the tutorial's decision tool)
  **and** `aggregate-vs-dcb-decision-guide.md`; removed only the redundant copies in
  `get-started`/`hybrid-based`. Two purposeful homes, not one.
- `4.6` — the tutorial ASCII cross-plugin diagrams were **removed** (replaced by tighter prose)
  rather than converted to d2; clearer for an overview and shorter.
- `docs-app/get-started.md` **grew** (+19) — correctness additions (pnpm provider set, Platform
  section) outweighed cuts. Correct trade-off.
- `5.3` — only the three flagged dates removed (get-started, component-overview,
  framework-internals); cosmetic `date:` on secondary component pages left as-is.
- `5.6` — `dcb-slices.md` two-`Products.res` disambiguation left for a later pass (low value).

**Actual line deltas (vs estimate):**

| Page | Was → Now | Δ actual | Δ est |
|---|---|---:|---:|
| `component-overview.md` | 764 → 322 | −442 | −334 |
| `development-process.md` | 429 → 115 | −314 | −149 |
| `tutorials/get-started.md` | 320 → 131 | −189 | −140 |
| `framework/get-started.md` | 105 → 14 | −91 | −93 |
| `framework-internals.md` | 101 → 54 | −47 | −41 |
| `hybrid-based.md` | 451 → 410 | −41 | −111 |
| `docs-app/index.md` | 96 → 66 | −30 | −30 |
| `framework/index.md` | 75 → 75 | 0 | −17 |
| `docs-app/get-started.md` | 118 → 137 | +19 | −13 |
| `markdown-page.md` (deleted) | 23 → 0 | −23 | — |
| **Total** | | **≈ −1,135** | ≈ −950 |

## Suggested commit slicing

1. Phase 1 correctness (one commit, or split 1.3/1.6 if large).
2. Phase 2 dedup + shortening (split per page if review wants smaller diffs).
3. Phase 3 consistency.
4. Phase 4 diagrams.
5. Phase 5 polish.

Each phase is independently shippable; verify the docs build (`pnpm --filter ./packages/doc run build`)
after Phases 1, 2, and 4 (link/route and d2-render regressions surface there).
