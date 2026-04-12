# Docs Broken Links & Anchors Fix Plan

## Summary

After completing the docs-review-and-cleanup plan, a build of the docs site (`npm run build`)
revealed broken links and anchors across several files. All are pre-existing — none were
introduced by the cleanup. The build still succeeds (`onBrokenLinks: "warn"` in
`docusaurus.config.js`) but the warnings indicate user-visible dead links.

Total broken items: ~80 (71 inner-workings source links + ~10 in app/framework docs)

---

## Issues Found

### 1. Broken anchor: `counter#usage-in-eventmappings` in `aggregate.md`

**File:** `docs-app/components/aggregate.md:276`

Links to `counter#usage-in-eventmappings` but the actual heading in `counter.md` is
`### Counter in EventMappings` → generates anchor `#counter-in-eventmappings`.

**Fix:** Change `#usage-in-eventmappings` → `#counter-in-eventmappings`.

---

### 2. Broken anchors: `component-overview#statechangeslice` and `#stateviewslice`

**Files:**
- `docs-app/components/statechangeslice.md:7` → `../component-overview.md#statechangeslice`
- `docs-app/components/stateviewslice.md:7` → `../component-overview.md#stateviewslice`

`component-overview.md` has sections for Aggregate, ReadModel, EventLog, etc. but no
`### StateChangeSlice` or `### StateViewSlice` sections.

**Fix:** Add `### StateChangeSlice` and `### StateViewSlice` summary sections to
`component-overview.md`, consistent with the existing `### Aggregate` pattern (lines 273–295).

---

### 3. Wrong relative path: `rescript-syntax.md#functors` in concepts files

**Files:**
- `docs-app/concepts/statechangeslice-usage.md:65` uses `./rescript-syntax.md#functors`
- `docs-app/concepts/stateviewslice-usage.md:60` uses `./rescript-syntax.md#functors`

`rescript-syntax.md` lives in `docs-app/`, not `docs-app/concepts/`. The `#functors` section
does exist at the correct target — the path prefix is just wrong.

**Fix:** Change `./rescript-syntax.md#functors` → `../rescript-syntax.md#functors` in both files.

---

### 4. Missing `dcb-usage.md` referenced from concepts files

**Files:**
- `docs-app/concepts/statechangeslice-usage.md:273,278` → `../../docs/dcb-usage.md`
- `docs-app/concepts/stateviewslice-usage.md:349` → `../../docs/dcb-usage.md`

No `dcb-usage.md` exists. The DCB walkthrough lives in `docs-app/dcb-based-plugin.md`.

**Fix:** Update links to point to `../dcb-based-plugin.md` (or remove the "See also" entries
if they add no value).

---

### 5. Non-existent event-modeling pages linked from component reference

**Files:**
- `docs-app/components/statechangeslice.md:255` → `./event-modeling-statechangeslice-usage.md`
- `docs-app/components/stateviewslice.md:245` → `./event-modeling-stateviewslice-usage.md`

These "Event Modeling: Usage" pages don't exist and appear to be planned future content.
The actual usage docs live in `docs-app/concepts/statechangeslice-usage.md` and
`docs-app/concepts/stateviewslice-usage.md`.

**Fix:** Update links to point to the existing `../concepts/statechangeslice-usage.md` and
`../concepts/stateviewslice-usage.md`.

---

### 6. Missing guide files referenced from component reference and slices pages

**Files referencing `docs/guides/reventless-ppx.md`:**
- `docs-app/components/readmodel.md:75`
- `docs-app/components/stateviewslice.md:202`
- `docs-app/dcb-slices.md:49` (as `../../guides/reventless-ppx.md#partitiontag-...`)

**Files referencing `docs/guides/querydb-key-design-guide.md`:**
- `docs-app/components/querydb.md:326`
- `docs-app/components/stateviewslice.md:202`
- `docs-app/components/readmodel.md:75`
- `docs-app/concepts/stateviewslice-usage.md:353`

Both guide files don't exist. Existing relevant content:
- PPX annotations are documented in `docs-app/rescript-syntax.md#ppx-annotations`
- No querydb key design guide exists anywhere yet

**Fix options:**
- A) Create `docs-framework/guides/reventless-ppx.md` and `querydb-key-design-guide.md`
     as real guides (preferred long-term)
- B) Update links in the referencing files to point to `rescript-syntax.md#ppx-annotations`
     and remove the querydb guide link or replace with a plain prose note

**Recommended:** Option B for now (unblock warnings without creating stub files); revisit
guide creation as a separate task.

---

### 7. Inner-workings pages: ~71 broken source file links

**Files:**
- `docs-framework/inner-workings/messages.md` (40 links to `packages/reventless{,-spec}/src/Message.res:N`)
- `docs-framework/inner-workings/pulumi.md` (10 links to `packages/reventless/src/components/...`)
- `docs-framework/inner-workings/resources.md` (5 links to `packages/reventless{-spec,-aws}/src/...`)
- `docs-framework/inner-workings/runtime.md` (5 links to `../../packages/reventless-aws/src/...`)
- `docs-framework/inner-workings/serialization.md` (3 links to `packages/reventless/src/components/Counter/...`)
- `docs-framework/inner-workings/component-structure-pattern.md` (links to `../../reventless/src/...`)
- `docs-framework/inner-workings/framework-inner-workings.md` (links to `../../reventless/src/...`)
- `docs-framework/inner-workings/mcp.md` (1 link to `/reventless-core/docs/guides/reventless-ppx#noapi`)

These pages use relative paths to `.res` source files as Markdown links. Docusaurus resolves
them as page paths, not source file references — so they always break.

**Fix:** Convert every source-file hyperlink to inline code (backtick reference without a link),
e.g. `[EventLog_Builder.res:26](...)` → `` `EventLog_Builder.res:26` ``.

This is the largest scope item (~71 occurrences across 8 files) but mechanical.

---

## Steps

- [ ] **Step 1** — Fix `aggregate.md:276`: `#usage-in-eventmappings` → `#counter-in-eventmappings`

- [ ] **Step 2** — Add `### StateChangeSlice` and `### StateViewSlice` sections to
  `component-overview.md` (follow the `### Aggregate` pattern)

- [ ] **Step 3** — Fix relative path in concepts files:
  - `statechangeslice-usage.md:65` (×2): `./rescript-syntax.md` → `../rescript-syntax.md`
  - `stateviewslice-usage.md:60` (×2): `./rescript-syntax.md` → `../rescript-syntax.md`

- [ ] **Step 4** — Fix `dcb-usage.md` links in concepts files:
  - `statechangeslice-usage.md:273,278`: point to `../dcb-based-plugin.md`
  - `stateviewslice-usage.md:349`: same

- [ ] **Step 5** — Fix event-modeling links in component reference:
  - `statechangeslice.md:255`: `./event-modeling-statechangeslice-usage.md` → `../concepts/statechangeslice-usage.md`
  - `stateviewslice.md:245`: `./event-modeling-stateviewslice-usage.md` → `../concepts/stateviewslice-usage.md`

- [ ] **Step 6** — Fix missing guide links (Option B):
  - `readmodel.md:75`, `stateviewslice.md:202`: update PPX link to `rescript-syntax.md#ppx-annotations`; update querydb link to a prose note or remove
  - `querydb.md:326`: remove or replace with prose note
  - `dcb-slices.md:49`: update PPX link to `../rescript-syntax.md#ppx-annotations`
  - `stateviewslice-usage.md:353`: same

- [ ] **Step 7** — Fix inner-workings source file links (71 occurrences across 8 files):
  convert every `[label](packages/reventless/...)` to plain `` `label` `` inline code

- [ ] **Step 8** — Rebuild docs (`cd packages/doc && npm run build`) and verify zero broken
  link/anchor warnings remain
