# Doc Link Integrity — repair every source link in `docs/analysis` and `docs/plans`

**Status:** Planned
**Date:** 2026-07-28
**Goal:** Every file link in every analysis and plan document — live, `Backlog/`, `done/`, `rejected/`, `postboned/` — resolves from the document's own directory, after accounting for the package renames and directory restructurings the repo has been through. Plus a CI guard so it stays that way.

---

## 1. Measured starting state

Scan of all 444 tracked `.md` files under `docs/analysis/` and `docs/plans/` (2026-07-28, at `fc20adf2f`):

| | Count |
|---|---|
| Files containing file links | 176 |
| File links (excluding `http(s):`, `mailto:`, bare `#anchor`) | 1883 |
| **Resolve correctly today** | **840** |
| **Broken** | **1043** |
| Files with ≥ 1 broken link | 135 (114 archived, 21 live) |
| Broken links by location | 914 archived, 129 live |
| Broken links by target | 771 → source code, 272 → other `.md` |
| Broken links by style | 855 already `../`-relative, 188 written bare/root-relative |

**The headline finding: this is not primarily a link-style problem.** Only **9** of 1043 are the repo-root-relative mistake (a bare path that would resolve from the repo root but not from the document). The other **1034** point at paths that no longer exist *anywhere* — they are casualties of renames and restructurings:

- **Package flattening.** `reventless/reventless-aws/` → `reventless/aws/`, `reventless-core/` → `core/`, `reventless-gwt/` → `gwt/`, `reventless-spec/` → `spec/`, `reventless-infra/` → `infra/`, and `reventless-in-memory/` → **`local/`** (a rename, not just a prefix strip). Same shape in `rescript/`: `rescript-pulumi-aws/` → `pulumi-aws/`.
- **Docs-site split.** `packages/doc/docs/` became four trees: `docs-app/`, `docs-framework/`, `docs-infrastructure/`, `docs-tutorials/`.
- **Ordinary file moves and deletions** across three years of refactoring (`git log` carries 7775 rename records and 3424 deletions).
- A handful of depth errors (`../` vs `../../`), which the 188 bare-style links are a variant of.

So the work is **90% path archaeology, 10% link style**. Any plan that only rewrites prefixes fixes 9 links out of 1043.

---

## 2. Resolution ladder

Rungs are tried in order; first hit wins. Yields below are measured against the real corpus, not estimated.

| Rung | Rule | Resolves |
|---|---|---|
| **0** | Discard regex false positives — a "target" that is literally `...` or `…` (prose ellipsis inside brackets, never a link) | 2 |
| **1** | **Depth fix.** Normalise the target against the doc's directory; if the result is a real file once the mis-anchored `docs/plans/…` prefix is stripped, the link was written root-relative. Re-emit at the correct depth. | 9 |
| **2** | **Folder rename map.** Apply `reventless/reventless-X/ → reventless/X/` (with `in-memory → local`), `rescript/rescript-X/ → rescript/X/`. | 169 |
| **3** | **Unique basename.** The basename occurs exactly once in `git ls-files`. Point at it. | 418 |
| **4** | **Ambiguous basename, longest-suffix match.** ≥ 2 candidates (worst offenders: `Platform.res` ×48, `Plugin.res` ×10, `Plugin_Builder.res` ×8, `index.md` ×9). Score each candidate by shared trailing path segments with the rename-normalised guess; accept at ≥ 2 segments, else fall through. | 128 |
| **5** | **Git rename-follow.** Build an old→new chain from `git log --all -M --diff-filter=ADR --name-status`, walk it, accept if the endpoint is tracked. Catches moves the basename rungs miss because the file was *also* renamed. | 44 |
| **6** | **Confirmed deleted.** The path (or its rename-followed endpoint) appears in the deletion set — the target genuinely no longer exists. **Policy decision, not an automated fix** (§3.1). | 43 |
| — | **Directory targets** (`…/adapter/Cloner/`). Same rename map, but existence-checked as a directory. Several point at directories that were dissolved entirely. | 31 |
| — | **Cross-repo** links into the UI repo. **Removed, not repaired** (§3.2). | 4 |
| — | **Unresolved.** Needs a human. | 102 |

**Automated coverage: 768 of 1043 (74%)** through rungs 0–5. Another 43 are mechanically *classified* by rung 6 but need a policy call. 137 (102 unresolved + 31 directories + 4 cross-repo) get human review, concentrated in a small number of files.

### 2.1 Why the unresolved 102 need judgement

Sampling them shows they are not one problem:

- **Renamed with a changed name, not just a moved path.** `reventless/core/src/admin/PluginReadModelSpec.res` → the successor is almost certainly `PluginsReadModelSpec.res` (singular → plural), now under `src/plugin/lifecycle/`. A basename match cannot see this; a human reading the plan can.
- **Deleted concepts.** `AdminApi.res`, `PluginProjection.res`, `Platform_UIDefinitions_Lambda.res` — components that no longer exist under any name. There is no correct target.
- **Aspirational paths.** Plans that linked to files the plan itself proposed creating, which were then created elsewhere or never created. `packages/doc/docs-app/components/command-handler-config.md` is one.
- **Sibling-doc links with wrong depth into a tree that also moved** — `./advanced.md`, `../analysis/aws-layer-per-branch-naming.md`, `../../get-started.md`.

---

## 3. Policy decisions

These need to be settled before Phase 2, because they change what the tool does rather than how it does it.

### 3.1 Links to files that genuinely no longer exist (43 + part of the 102)

Three options:

- **(a) Delete the link, keep the text.** `[Foo.res](…)` → `` `Foo.res` ``. Honest, no dead link, and the historical record still names the file.
- **(b) Point at the successor concept** where one exists, even if the name changed. Preserves navigability; risks asserting an equivalence that is not exact.
- **(c) Leave it.** A `done/` plan is a historical document; a link to a file that existed when the plan was written is arguably accurate.

**Recommended: (a) as the default, (b) where the successor is unambiguous and the plan is still referenced.** (c) is rejected because it makes the CI guard in Phase 4 impossible — there would be no clean baseline.

### 3.2 Cross-repo links (4)

Links into the UI repo's `docs/plans/`. **Remove the link entirely**, keeping any descriptive text, per the standing convention that core docs never reference the UI repo's own repo/plans/docs (naming the npm package is fine). Not a repair — a removal.

### 3.3 Archived vs live

All 444 files are in scope, per the request. Worth noting the split so review effort lands where it matters: **129 broken links sit in 21 live documents**, 914 in 114 archived ones. Phase order reflects this — live first, so the payoff is immediate and the risky bulk edit is reviewed second.

### 3.4 Line anchors

`#L152` / `#L131-L182` anchors are preserved verbatim by every rung. **They will frequently be wrong** — the file moved and its contents changed, so the line numbers refer to a version that no longer exists. Re-deriving them is out of scope: it would require resolving each link against the commit the doc was written at, and for archived plans the anchor is arguably part of the historical record. Flag as a known limitation; do not attempt.

---

## 4. Phases

### Phase 0 — Land the checker (no content changes)

`scripts/check-doc-links.mjs`:

- Enumerate `.md` under `docs/` from `git ls-files` (**pathspec must be `git ls-files docs/analysis docs/plans` + an `.endsWith(".md")` filter — the glob form `'docs/**/*.md'` silently drops every file at the top level of each directory**, which under-reported this very corpus by 88 files on the first pass).
- Resolve each link against the containing file's directory. Skip `http(s):`, `mailto:`, bare `#`.
- **Skip code spans and fenced blocks.** A doc that *discusses* link syntax contains `` `[Foo.res](…)` `` as an example; a naive regex reads it as a broken link. This plan tripped its own checker on exactly that, in §3.1.
- Report: file, line, target, and the rung classification.
- Exit non-zero on any unresolved link; `--report` mode prints without failing.

Wire as `pnpm run check:doc-links`. Not in CI yet — the corpus is red.

*Deliverable:* the checker, and a committed baseline report so progress is measurable.

### Phase 1 — Live documents (21 files, 129 links)

Run rungs 0–5, review every proposed rewrite, apply. Resolve the residual by hand. These are documents people actually navigate from, and the small volume makes careful review cheap.

*Exit:* `check:doc-links` clean for all non-archived files.

### Phase 2 — Archived documents (114 files, 914 links)

Same ladder, applied per directory (`Backlog/` → `rejected/` → `postboned/` → `done/`) so each commit is reviewable in isolation. `done/` is by far the largest and goes last.

The tool writes a **proposal file** (target → replacement, with the rung that produced it) rather than editing in place. Review the proposals for rungs 3–5 in bulk — rung 3 (unique basename) is near-certain, rung 4 (ambiguous) is the one to actually read, rung 5 (git-follow) is worth spot-checking. Then apply.

*Exit:* `check:doc-links` clean everywhere; policy 3.1/3.2 applied to what remains.

### Phase 3 — Rename map as durable knowledge

The rung-2 map and the deleted-concept decisions from 3.1 are the reusable output. Record them in the plan's completion notes and in `docs/guides/` alongside the doc conventions, so the next restructuring has a starting point rather than rediscovering it.

### Phase 4 — CI guard

Add `check:doc-links` to the docs job. New docs must link relatively and resolve; a source rename that orphans a doc link fails the build that made it, not a scan three years later.

Consider also: a `--fix` mode restricted to rungs 1–2 (unambiguous, mechanical) so an ordinary package rename self-heals.

---

## 5. Risks

| Risk | Mitigation |
|---|---|
| **Rung 3/4 point at a plausible wrong file.** 48 files named `Platform.res`; longest-suffix scoring can pick the wrong one. | Rung 4 requires ≥ 2 shared trailing segments and is reviewed as its own batch. Rung 3 (unique basename) has no such ambiguity by construction. |
| **Bulk edit corrupts a doc.** 914 rewrites across 114 files. | Tool emits proposals, never edits in place; apply as a separate mechanical step; one commit per archive directory; the checker re-verifies after apply. |
| **Rewriting history that should stay historical.** A `done/` plan repaired to point at today's code can read as if it described today's code. | Policy 3.1(a) is deliberately conservative — de-link rather than re-point when the target is gone. Where 3.1(b) is used, the successor must be an actual rename, not a conceptual cousin. |
| **Line anchors silently wrong after repair.** | Documented as a known limitation (§3.4), not silently "fixed". |
| **Checker's own pathspec bug.** | Called out explicitly in Phase 0; the checker's first test asserts it sees a top-level file in `docs/analysis/`. |

---

## 6. Acceptance criteria

- [ ] `pnpm run check:doc-links` exits 0 across all 444 files.
- [ ] Every remaining link is either relative-and-resolving, or was deliberately de-linked under policy 3.1/3.2.
- [ ] No link in `docs/` points into the UI repo.
- [ ] The rename map is recorded somewhere a future restructuring will find it.
- [ ] The checker runs in CI and fails on a newly-orphaned link.
- [ ] Known limitation documented: line anchors in archived plans are not re-derived.

---

## 7. Related

- [platform-main-capability-provisioning.md](../analysis/platform-main-capability-provisioning.md) — the analysis whose link fix-up surfaced this; already converted to relative links.
- [d2-diagrams.md](../../packages/doc/docs-framework/d2-diagrams.md) — the other doc-authoring convention with a mechanical check behind it. (Its guide lives under `packages/doc/docs-framework/`, not `docs/guides/` — exactly the kind of move that produced the 1034 dead links, and it caught this plan's own first draft.)
