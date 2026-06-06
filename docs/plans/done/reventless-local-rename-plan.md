# Rename `reventless-in-memory` → `reventless-local` — Implementation Plan

**Status:** DONE (code-complete) — Phases 0–7 finished & verified (incl. Phase 1/6 UI `authMode`). Only Phase 8 (publish/deprecate the core package) remains, and that runs automatically via core's release CI on push to `alpha` — no further manual code work. Filed in `done/`.
**Date:** 2026-06-06
**Analysis:** [docs/analysis/reventless-local-rename.md](../analysis/reventless-local-rename.md)
**Type:** Breaking rename (standalone, mechanical PR)

> Update this file after every step (tick the box, note surprises). When all steps are done, `git mv` this file to `docs/plans/done/` **in the final commit**.

## Execution status (2026-06-06)

- ✅ Core rename complete: package `@reventlessdev/reventless-local@3.0.0-alpha.86`, namespace `ReventlessLocal`, dir, 21 adapters, 3 example platforms, codegen, root `jest.config.js`, `.github/workflows/ci.yml`, `scripts/setup.mjs`, docs-site folder + sidebar, CLAUDE.md, conventions.
- ✅ Verified: `pnpm run build` zero warnings · full suite **189 suites / 1448 tests pass** · codegen **golden tests green** · lockfile clean symmetric rename (no `reventless-ui` contamination).
- ⚠️ **Deviation from OQ1 target:** the "drop suffix → bare names" plan was **not** used. Bare names collide with the functor parameter `Bus` and with 6 `reventless-core` modules opened via `open Reventless` (`PluginSpec`, `SideEffectHandler`, `QueryEngine`, the three `*Runtime_Builder`). **Resolution: uniform `Local` prefix** for all 21 always-in-process adapters (`LocalBus`, `LocalQueryEngine`, …). Still satisfies the intent (`_InMemory` now marks only a SQLite-twinned surface). Convention recorded in `.claude/rules/component-guidelines.md`.
- ✅ **DONE — Phase 1/6 (OQ3, `authMode`):** the `authMode` config string lives in the **UI repo** (`reventless-host-shell/public/config.json`), not core (core ships no authMode config; AWS deploys emit `"cognito"`). reventless-ui changes: dual-accept `"local"`+`"inmemory"` and variant `InMemory`→`Local` (released as **host-shell alpha.27**), then config default flipped to `"local"` (released as **host-shell alpha.28**). Core re-pinned `platform-aws` + `platform-local` to **alpha.27** then **alpha.28** (commits `47696ec9c`, `cf57e5917`). The `provider: InMemory` variant, `"memory:InMemory"` service tags, and `/__inmemory/login` route were deliberately kept (backend-mechanism contract).
- ⏸️ Phase 8 (publish/deprecate the core package) — not started; happens via core release CI on push to `alpha`.
- Historical `docs/plans/done/` + `docs/analysis/` left untouched (historical record, per repo convention).

---

## Decisions carried from the analysis

- **OQ1:** Keep `_InMemory` on the **3 persisted storage surfaces** (they have a `_Sqlite` twin); for the **21 always-in-process adapters**, drop the suffix — *implemented as a uniform `Local` prefix* (see deviation note above; bare names collide).
- **OQ2:** Continue the version line — new package starts at `3.0.0-alpha.86`. ✅ done.
- **OQ3:** Rename the UI `authMode` string `"inmemory"` → `"local"` via a dual-accept lockstep. ✅ done (host-shell alpha.27 dual-accept + alpha.28 config default; core re-pinned).
- **OQ4:** Ship as a **standalone** mechanical rename PR.

## Target names

| Old | New |
|---|---|
| package `@reventlessdev/reventless-in-memory` | `@reventlessdev/reventless-local` |
| dir `reventless/reventless-in-memory/` | `reventless/reventless-local/` |
| namespace `ReventlessInMemory` | `ReventlessLocal` |
| dirs `examples/*/platform-in-memory/` | `examples/*/platform-local/` |
| packages `@reventlessdev/online-shop-*-platform-in-memory` | `…-platform-local` |
| docs `docs-infrastructure/in-memory/` (+ D2) | `docs-infrastructure/local/` |
| config string `"authMode": "inmemory"` | `"local"` |

**KEEP unchanged (the 3 persisted surfaces):** `EventLogStorage_InMemory`, `DcbEventLogStorage_InMemory`, `QueryDbStorage_InMemory` (each paired with its `_Sqlite` sibling).

---

## Phase 0 — Pre-flight (no edits yet)  ✅ DONE

- [ ] Create branch off `alpha`: `git checkout -b rename/reventless-local`
- [ ] Snapshot the rename surface for later diffing:
  - [ ] `git grep -l "ReventlessInMemory"` → save list
  - [ ] `git grep -l "reventless-in-memory"` → save list
  - [ ] `git grep -lE "InMemory_|_InMemory"` → save list
- [ ] Confirm clean working tree (only the known `examples/online-shop-hybrid/*/package.json` `M` entries from before — stash/commit/ignore as appropriate).
- [ ] Confirm overlay state: if any sibling-repo (`reventless-ui`) edits will happen, run `pnpm run link:on`. Otherwise stay in release mode so the lockfile/workspace stay clean.
- [ ] Baseline green: `pnpm run build 2>&1 | grep -E "Warning|warning|error|Error"` (expect empty) and `pnpm test` on the in-memory package.

---

## Phase 1 — UI lockstep, part 1 (reventless-ui) — decided OQ3  ✅ DONE (released as host-shell alpha.27)

> Do this **before** flipping `config.json` (the UI host-shell bundled default `reventless-host-shell/public/config.json` — NOT core; core ships no authMode config), so neither repo points at a value the other rejects.

- [ ] In **reventless-ui**, find the `authMode` consumer (grep `inmemory` / `authMode` in the UI repo).
- [ ] Widen the check to accept **both** `"inmemory"` and `"local"` (alias, don't replace yet).
- [ ] Build/test the UI package locally with `pnpm link:on` active to confirm it compiles.
- [ ] Release the UI package the normal way; **read the new version from its git tag** (do NOT hand-bump / `lerna version` in the UI repo).
- [ ] Bump the host-shell pin in core (`reventless-host-shell`) to that **exact** tagged version.
- [ ] Verify host-shell builds against the new UI version.

*(If the UI release cadence makes this slow, Phase 2–5 can proceed in parallel; only Phase 6 — the `config.json` flip — is gated on Phase 1 landing.)*

---

## Phase 2 — Core package rename (identity)  ✅ DONE

Single focused set of edits in `reventless/reventless-in-memory/`:

- [ ] `git mv reventless/reventless-in-memory reventless/reventless-local`
- [ ] In `reventless/reventless-local/package.json`: set `name` → `@reventlessdev/reventless-local`, `version` → `3.0.0-alpha.86`.
- [ ] In `reventless/reventless-local/rescript.json`: set `namespace` → `ReventlessLocal` (and the package `name` field if present).
- [ ] Find-and-replace `ReventlessInMemory` → `ReventlessLocal` across the whole repo (all `.res`/`.resi`/`.md` consumers, not just the package).
- [ ] Update the **27 config files** that reference `@reventlessdev/reventless-in-memory`:
  - root `package.json` (devDeps) + root `rescript.json` (deps)
  - 3 example `platform-*` (`package.json` + `rescript.json`)
  - 6 example plugins `catalog/` + `ordering/` (`package.json` + `rescript.json`)
  - 2 codegen golden **input** fixtures under `reventless-codegen/tests/fixtures/.../*` if they carry the dep (verify), and the **golden output** copies under `tests/golden/dilger/*`
  - Drive it: `git grep -l "reventless-in-memory" -- '*.json'` and edit each.
- [ ] Update `pnpm-workspace.base.yaml` / `lerna.json` only if they name the package explicitly (they use the `reventless/*` glob, so likely no change — verify).
- [ ] `pnpm install` **only if** needed to refresh `workspace:*` links — guard against lockfile contamination (revert `pnpm-lock.yaml` UI entries if overlay is active).

---

## Phase 3 — Suffix normalization (decided OQ1)  ✅ DONE (uniform Local prefix — see deviation note)

Inside `reventless/reventless-local/`, **drop** the `_InMemory` marker on the always-in-process adapters. For **each** module below: `git mv` the `.res` (+ `.resi` if any), rename the inner reference, and fix every usage repo-wide.

KEEP (do not touch the suffix): `EventLogStorage_InMemory`, `DcbEventLogStorage_InMemory`, `QueryDbStorage_InMemory`.

Drop the suffix → bare name:

- [ ] `adapter/InMemory_Bus` → `Bus`  ⚠️ also fix `InMemory_Bus.T` → `Bus.T` in the **`_Sqlite`** functor signatures and in `Platform.res`
- [ ] `adapter/InMemory_PluginSpec` → `PluginSpec`
- [ ] `adapter/SideEffectHandler_InMemory` → `SideEffectHandler`
- [ ] `adapter/Auth/Auth_InMemory` → `Auth`  ⚠️ check test names (`Auth_InMemory*Test.res`)
- [ ] `adapter/CommandTopic/CommandTopicChannel_InMemory` → `CommandTopicChannel`
- [ ] `adapter/CommandTopic/CommandTopicRemoteChannel_InMemory` → `CommandTopicRemoteChannel`
- [ ] `adapter/CommandGenerator/CommandGeneratorResolvers_InMemory` → `CommandGeneratorResolvers`
- [ ] `adapter/Cloner/ClonerRunner_InMemory` → `ClonerRunner`
- [ ] `adapter/Counter/CounterHandler_InMemory` → `CounterHandler`
- [ ] `adapter/EventCollector/EventCollectorChannel_InMemory` → `EventCollectorChannel`
- [ ] `adapter/EventTopic/EventTopicPublisher_InMemory` → `EventTopicPublisher`
- [ ] `adapter/Heartbeat/HeartbeatRunner_InMemory` → `HeartbeatRunner`
- [ ] `adapter/QueryEngine/QueryEngine_InMemory` → `QueryEngine`
- [ ] `adapter/Runtime/AggregateRuntime_Builder_InMemory` → `AggregateRuntime_Builder`
- [ ] `adapter/Runtime/EventCollectorRuntime_Builder_InMemory` → `EventCollectorRuntime_Builder`
- [ ] `adapter/Runtime/PluginRuntime_Builder_InMemory` → `PluginRuntime_Builder`
- [ ] `adapter/Runtime/RuntimeEnvironment_InMemory` → `RuntimeEnvironment`
- [ ] `adapter/Scheduler/ScheduledPublisher_InMemory` → `ScheduledPublisher`
- [ ] `adapter/Task/TaskBucket_InMemory` → `TaskBucket` (no `_Sqlite` twin today)
- [ ] `adapter/Api/GraphQL_InMemory_Adapter` → `GraphQL_Adapter`
- [ ] `adapter/Api/GraphQL_SubscriptionResolvers_InMemory` → `GraphQL_SubscriptionResolvers`

Per-module checklist:
- [ ] **Collision check before each drop:** `git grep -n "module <BareName> " reventless/reventless-local/` — ensure no existing `components/` builder or core interface already owns the bare name *within the package*. If it collides, keep a qualifier (note it here).
- [ ] Remember the memory rule: `git mv` stages the rename only — `git add` the edited file content too (status shows `RM`).

---

## Phase 4 — Example platforms + golden fixtures  ✅ DONE

- [ ] For each of the 3 examples: `git mv examples/<app>/platform-in-memory examples/<app>/platform-local`
- [ ] In each renamed platform `package.json`: rename `name` → `@reventlessdev/online-shop-<app>-platform-local`.
- [ ] Update any references to the old platform package name / dir (scripts, READMEs, `Main.res`, run scripts).
- [ ] Regenerate codegen golden fixtures so `ForwardGoldenTest.res` matches:
  - [ ] run the golden-regeneration path for `reventless-codegen` (the forward test's update mode), or hand-edit the 2 golden outputs under `tests/golden/dilger/*`.
  - [ ] `cd reventless/reventless-codegen && pnpm test` → green.

---

## Phase 5 — Docs & conventions sweep  ✅ DONE

- [ ] Vocabulary: "in-memory platform" → "local platform" across `README.md`, `CLAUDE.md`, `docs/guides/*`, `docs/analysis/*` (current/non-historical), the platform-and-plugin guide.
- [ ] `git mv packages/doc/docs-infrastructure/in-memory packages/doc/docs-infrastructure/local` (+ the `static/d2/docs-infrastructure/in-memory/` D2 dir; `build/` is generated — ignore).
- [ ] Add Docusaurus redirects for the changed route(s).
- [ ] Update `CLAUDE.md`: package list entry, per-package command examples, package-table description.
- [ ] **Record the new suffix convention** in `.claude/rules/component-guidelines.md` (or conventions.md): *`_InMemory` ⇄ `_Sqlite` only where a real backend choice exists; in-process-only adapters carry no suffix.*
- [ ] Rename/edit the Backlog plan `docs/plans/Backlog/reventless-vscode-in-memory-platform-runner.md` (describes future work). Leave `docs/plans/done/*` historical plans untouched.
- [ ] Optionally update this repo's memory index entries that name the package (not required for the PR).

---

## Phase 6 — UI lockstep, part 2 (the `config.json` flip)  ✅ DONE (host-shell alpha.28; core re-pinned)

> Gated on Phase 1 having landed (UI accepts both values).

- [ ] In `reventless-host-shell/public/config.json`: `"authMode": "inmemory"` → `"local"`.
- [ ] Verify the host-shell + UI still authenticate locally (LoginPage / defaultUser path) per the in-memory dev rules.

---

## Phase 7 — Build, verify, commit  ✅ DONE (build green · 189 suites / 1448 tests) — commit pending user approval

- [ ] Full rebuild from root: `pnpm run build`
- [ ] Zero-warning gate: `pnpm run build 2>&1 | grep -E "Warning|warning|error|Error"` → empty
- [ ] `pnpm test` across affected packages (local package, codegen golden, examples).
- [ ] Re-commit regenerated in-source `.res.mjs` (namespace + suffix changes alter emitted output — ~485 files). Confirm none were accidentally deleted (`git ls-files --deleted`); recover with `git checkout --` if `clean` was run.
- [ ] Sanity grep: `git grep -i "reventless-in-memory"` and `git grep "ReventlessInMemory"` → only intended historical mentions (done-plans) remain.
- [ ] `git grep -nE "_InMemory|InMemory_"` → only the **3 persisted storage surfaces** (+ their references) remain.
- [ ] `git mv` this plan to `docs/plans/done/` as part of the final commit.

---

## Phase 8 — Publish (release branch / CI, after merge)  ⏸️ NOT STARTED (post-merge)

- [ ] Lerna publishes `@reventlessdev/reventless-local@3.0.0-alpha.86` and the renamed `…-platform-local` packages.
- [ ] **Deprecate** `@reventlessdev/reventless-in-memory` with a pointer to the new name (supersede — do NOT rely on GitHub Packages dist-tag moves).
- [ ] Release notes: call out the package rename + the `_InMemory`-suffix convention change.
- [ ] Follow-up: once the new UI tag is everywhere, **drop the `"inmemory"` alias** from the UI auth check.

---

## Risks to watch during execution

- **Suffix-drop collisions** — generic names (`Bus`, `CommandTopicChannel`, `TaskBucket`) may clash with a `components/` builder or core interface *inside the package*. Check before each drop; keep a qualifier if needed.
- **`InMemory_Bus.T` in `_Sqlite` signatures** — the kept storage modules reference the renamed bus type; easy to miss.
- **Lockfile contamination** — avoid `pnpm install` with the UI overlay active; revert UI entries in `pnpm-lock.yaml` before committing.
- **`git mv` + edit** — always `git add` the moved-and-edited files (`RM` status).
- **Golden fixtures** — a missed regeneration turns `ForwardGoldenTest.res` red.
- **Docs route break** — add redirects for the renamed Docusaurus folder.
