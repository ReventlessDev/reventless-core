# Renaming `reventless-in-memory` → `reventless-local` — Analysis

**Status:** Analysis
**Date:** 2026-06-06
**Scope:** Rename the `reventless-in-memory` package (and the broader "in-memory" vocabulary) to "local", on the premise that the platform supports **both** a pure in-memory backend and a SQLite-backed one.

> **Update (2026-07-02):** this analysis was written while `@reventlessdev/*` published to the
> **private GitHub Packages** registry. That has since changed — publishing migrated to
> **public npmjs** (`registry.npmjs.org`) and the repo is public. Where the text below reasons
> about a "private registry" or GitHub-Packages dist-tag unreliability as a *constraint on the
> rename*, read it as historical: on public npmjs the rename is still a **new package +
> deprecate-old** operation (npm likewise cannot rename a published package in place), so the
> analysis's conclusion is unchanged; only the registry named is now npmjs.

---

## Executive Summary

The package named `@reventlessdev/reventless-in-memory` is no longer purely in-memory. It already ships a `Backend` selector ([Backend.res](../../reventless/reventless-in-memory/src/adapter/Backend.res)) with two arms — `Memory` and `Sqlite({path, resetOnStart})` — wired through `Platform.MakeWithConfig`, driven by an env var that is **already** called `REVENTLESS_LOCAL_BACKEND`, and documented under "local persistence" ([docs/analysis/in-memory-local-persistence.md](in-memory-local-persistence.md)) and a "local dev" guide ([docs/guides/local-dev.md](../guides/local-dev.md)). Every durable storage surface already has a `*_InMemory.res` **and** a `*_Sqlite.res` implementation. The product is a **local platform** with a pluggable backend; the package name lags behind the code.

> **Implementation outcome (2026-06-06):** shipped. One deviation from the analysis below — the "Always-in-process adapter" layer was **not** renamed to *bare* names (`Bus`, `QueryEngine`, …). Bare names collide with the ubiquitous functor parameter `Bus` and with ~6 `reventless-core` modules pulled in via `open Reventless` (`PluginSpec`, `SideEffectHandler`, `QueryEngine`, the three `*Runtime_Builder`). The build surfaced these collisions, so the shipped resolution is a **uniform `Local` prefix** (`LocalBus`, `LocalQueryEngine`, `LocalCommandTopicChannel`, …). This still satisfies the intent — `_InMemory` now marks *only* a SQLite-twinned storage surface — and is recorded as a convention in [.claude/rules/component-guidelines.md](../../.claude/rules/component-guidelines.md). Read the "Drop the suffix → bare name" passages below as "drop `_InMemory`, prefix `Local`". The auth `provider: InMemory` variant, `"memory:InMemory"` service tags, and the `/__inmemory/login` route were deliberately kept (backend-mechanism contract).

**Recommendation: do the rename — but scope it to identity, not to backend labels.**

There are **three** distinct layers wearing the word "in-memory", and they must be treated differently:

| Layer | Example | Verdict |
|---|---|---|
| **Platform / package / namespace identity** | package `reventless-in-memory`, namespace `ReventlessInMemory`, dirs `platform-in-memory/` | **Rename → `local` / `ReventlessLocal`.** This is the misnomer. |
| **Backend discriminator** (a `_Sqlite` sibling exists) | `EventLogStorage_InMemory` ⇄ `EventLogStorage_Sqlite` | **Keep `_InMemory`.** Here it is a *precise* backend label; renaming it to `_Local` makes it indistinguishable from `_Sqlite`, which is *also* local. |
| **Always-in-process adapter** (no `_Sqlite` sibling) | `InMemory_Bus`, `CommandTopicChannel_InMemory`, `ScheduledPublisher_InMemory` | **Drop the `_InMemory` suffix** → `LocalBus`, `LocalCommandTopicChannel`, `LocalScheduledPublisher` (shipped as `Local`-prefixed, not bare — see implementation outcome above). The suffix is noise here: there is no alternative backend to discriminate against. (Per **decided OQ1** — normalize these.)|

A literal "rename everything in-memory to local" is the wrong instruction. The decided policy makes the suffix **mean something**: `_InMemory` appears **only** where a real `_InMemory` ⇄ `_Sqlite` choice exists; everywhere else the suffix is dropped (and the module is `Local`-prefixed). Identity moves to `local`; the three persisted storage surfaces keep their backend label; the always-in-process plumbing sheds the suffix.

This is a **good idea**, with a moderate-but-contained mechanical cost, gated mainly by the fact that the package is published to a private registry (so a rename is a *new package*, not a move).

---

## Why the rename is justified

1. **The code already moved; only the label is stale.** SQLite arms exist for EventLog, DcbEventLog, and QueryDb; the env var is `REVENTLESS_LOCAL_BACKEND`; the persistence analysis and dev guide already say "local". The rename closes a gap that the codebase opened months ago.
2. **"In-memory" actively misleads new users.** It reads as "ephemeral, test-only, wiped on restart" — which is exactly the property SQLite removes. A developer doing live UI/QA work against a persistent SQLite file is using a platform whose name tells them their data vanishes.
3. **"Local" is the correct genus.** The platform's defining trait is *where* it runs (in-process, no cloud, single node), not *how* it stores. "Local" subsumes both backends and leaves room for a third (e.g. file-snapshot, LMDB) without another rename.
4. **It mirrors the AWS package framing.** `reventless-aws` is named for its *deployment target*, not its storage tech. `reventless-local` parallels that cleanly: the axis becomes **local vs aws**, not **in-memory vs aws**.

---

## What "local" should and should NOT touch

### Rename (identity layer)

- **Package:** `@reventlessdev/reventless-in-memory` → `@reventlessdev/reventless-local`
- **Directory:** `reventless/reventless-in-memory/` → `reventless/reventless-local/`
- **ReScript namespace:** `ReventlessInMemory` → `ReventlessLocal` (rescript.json `namespace`)
- **Example platform dirs/packages:** `examples/*/platform-in-memory/` → `platform-local/` (and their package names `@reventlessdev/online-shop-*-platform-in-memory` → `…-platform-local`)
- **Docs vocabulary:** "the in-memory platform" → "the local platform"; README, CLAUDE.md, guides, docs site folder `docs-infrastructure/in-memory/` → `docs-infrastructure/local/`
- **Config string:** `config.json` `"authMode": "inmemory"` in reventless-host-shell → `"local"` (one string, UI side; coordinate with the UI repo)

### Keep `_InMemory` — the 3 persisted storage surfaces (paired with `_Sqlite`)

These have a `*_Sqlite.res` sibling; the suffix is a real backend discriminator and stays:

- `EventLog/EventLogStorage_InMemory` ⇄ `EventLogStorage_Sqlite`
- `DcbEventLog/DcbEventLogStorage_InMemory` ⇄ `DcbEventLogStorage_Sqlite`
- `QueryDb/QueryDbStorage_InMemory` ⇄ `QueryDbStorage_Sqlite`

### Drop the suffix — always-in-process adapters (decided OQ1)

No `_Sqlite` sibling exists, so the `_InMemory` marker is noise. Normalize to the bare name (in the `ReventlessLocal` namespace):

| Current | →  Normalized |
|---|---|
| `InMemory_Bus` (prefix form) | `Bus` |
| `InMemory_PluginSpec` (prefix form) | `PluginSpec` |
| `SideEffectHandler_InMemory` | `SideEffectHandler` |
| `Auth/Auth_InMemory` | `Auth` |
| `CommandTopic/CommandTopicChannel_InMemory` | `CommandTopicChannel` |
| `CommandTopic/CommandTopicRemoteChannel_InMemory` | `CommandTopicRemoteChannel` |
| `CommandGenerator/CommandGeneratorResolvers_InMemory` | `CommandGeneratorResolvers` |
| `Cloner/ClonerRunner_InMemory` | `ClonerRunner` |
| `Counter/CounterHandler_InMemory` | `CounterHandler` |
| `EventCollector/EventCollectorChannel_InMemory` | `EventCollectorChannel` |
| `EventTopic/EventTopicPublisher_InMemory` | `EventTopicPublisher` |
| `Heartbeat/HeartbeatRunner_InMemory` | `HeartbeatRunner` |
| `QueryEngine/QueryEngine_InMemory` | `QueryEngine` |
| `Runtime/AggregateRuntime_Builder_InMemory` | `AggregateRuntime_Builder` |
| `Runtime/EventCollectorRuntime_Builder_InMemory` | `EventCollectorRuntime_Builder` |
| `Runtime/PluginRuntime_Builder_InMemory` | `PluginRuntime_Builder` |
| `Runtime/RuntimeEnvironment_InMemory` | `RuntimeEnvironment` |
| `Scheduler/ScheduledPublisher_InMemory` | `ScheduledPublisher` |
| `Task/TaskBucket_InMemory` | `TaskBucket` † |
| `Api/GraphQL_InMemory_Adapter` | `GraphQL_Adapter` |
| `Api/GraphQL_SubscriptionResolvers_InMemory` | `GraphQL_SubscriptionResolvers` |

† TaskBucket is currently a no-op stub with no `_Sqlite` arm, so it drops the suffix. **If** a persistent task bucket lands later, it would *re-introduce* `TaskBucket_InMemory` ⇄ `TaskBucket_Sqlite` — an accepted churn cost of making the suffix meaningful. Same applies to any other surface that later grows a SQLite arm.

> The crisp rule: **rename the noun that names the *platform*; keep `_InMemory` only where a `_Sqlite` twin makes it a real choice; drop it everywhere else.** "Local platform, in-memory `EventLogStorage` (vs the SQLite one)" is meaningful; "in-memory `Bus`" is redundant because there is no other kind of bus.

**Watch-outs for the suffix drop:**
- `InMemory_Bus.T` is referenced in functor signatures of the *Sqlite* storage modules (e.g. `DcbEventLogStorage_Sqlite = (Bus: InMemory_Bus.T, …)`); those references update to `Bus.T` too.
- The bare names live inside the `ReventlessLocal` namespace, so generic names like `Bus`, `CommandTopicChannel`, `TaskBucket` won't collide with the interfaces of the same conceptual name defined in `reventless-core` — but reviewers should confirm no *intra-package* collision is introduced (e.g. a `components/` builder already named `CommandTopicChannel`).

---

## Inventory of the rename surface

From a repo-wide sweep (excluding `node_modules`, `lib/`, generated `.res.mjs`):

| Surface | Count | Notes |
|---|---|---|
| Config files referencing the npm name | **27** `package.json` + `rescript.json` | root, 3 example platforms, 6 example plugins, 2 codegen golden fixtures, the package itself |
| ReScript namespace `ReventlessInMemory` | global prefix | every export; consumers import `ReventlessInMemory.*` |
| `*_InMemory` adapter modules | **24** | **3 keep** the suffix (persisted storage); **~21 get renamed** (suffix dropped — decided OQ1) + every reference to them across the package |
| Directories with "in-memory"/"platform-in-memory" | **7** | 1 package, 3 example platforms, 3 docs/build dirs |
| Markdown ("in-memory"/"InMemory") | ~1,870 lines / many files | README, CLAUDE.md, guides, plans, analysis, docs site |
| Workspace/build config | `pnpm-workspace.base.yaml`, `lerna.json`, root `rescript.json`, root `package.json` | covered by `reventless/*` glob, but the explicit dependency entries must change |
| reventless-ui sibling repo | **1** string (`"authMode": "inmemory"` → `"local"`) | not a package dependency, but a consumed value — cross-repo lockstep (decided OQ3) |

**Generated `.res.mjs`:** ~485 files are tracked compiled outputs (per the in-source `.res.mjs` tracking convention). A namespace rename changes the emitted module prefix, so these regenerate and must be re-committed alongside the rename. This roughly doubles the diff size but is mechanical.

---

## Consequences

### 1. It is a new package, not a move (biggest consequence)

The package publishes to the **private GitHub Packages registry** under `@reventlessdev/*`. Renaming the npm name means:

- **Decided (OQ2): continue the version line.** `@reventlessdev/reventless-local` picks up where `reventless-in-memory` left off (currently `3.0.0-alpha.85`) rather than resetting to `1.0.0`, so semver intent stays legible across the rename. Practically: set the new package's initial `version` to the next alpha (`3.0.0-alpha.86`) and let Lerna carry it forward — do **not** let Lerna treat it as a brand-new `0.0.0` package.
- The old `@reventlessdev/reventless-in-memory` should be **deprecated** (npm/GitHub Packages `deprecate`) pointing at the new name. GitHub Packages does not move dist-tags reliably (see [reventless-ppx publishing pitfalls](../../../.claude/projects/-Users-martin-prj-ReventlessDev-reventless-core/memory/reference_reventless_ppx_publishing_pitfalls.md) in memory) — plan to supersede/deprecate, not rename in place.
- Because every consumer in this monorepo uses `workspace:*`, **internal consumers update atomically** in the same commit. There is no external-consumer break to manage *as long as* no out-of-repo project depends on the old name (the UI repo does not).
- **Lerna/release impact:** the new package and the three renamed `…-platform-local` example packages get fresh changelogs. The first release after the rename will look like "new package added + old package final/deprecated" — acceptable, but call it out in the release notes.

### 2. ReScript namespace break

`ReventlessInMemory.*` → `ReventlessLocal.*` is a hard rename across every importing `.res` file (core, spec, examples, tests). There is no aliasing in ReScript namespaces, so this is a find-and-replace + rebuild, verified by the zero-warnings gate (`pnpm run build 2>&1 | grep -E "Warning|warning|error|Error"`).

### 3. Git history / blame

Use `git mv` for the directory and every file so history is preserved (the per-file rename of 24 adapters + tests is the bulk). Note the memory rule: **`git mv` only stages the rename — edits to the moved file still need `git add`**, and namespace edits touch every moved file, so expect `RM` statuses that need a follow-up `git add`.

### 4. Codegen golden fixtures

Two golden fixtures under `reventless-codegen/tests/golden/dilger/*` reference the package name and will need regenerating so `ForwardGoldenTest.res` stays green. This is a real test-suite touch-point, not just docs.

### 5. Docs site routing

`docs-infrastructure/in-memory/` is a Docusaurus route. Renaming the folder changes URLs — add redirects (or accept the break on an unreleased docs site). The D2 diagram folder under `static/d2/` and `build/` follow.

### 6. Coordination with the UI repo (now in scope — decided OQ3)

**Decided (OQ3): rename the `authMode` string `"inmemory"` → `"local"`.** This makes the package rename a **cross-repo lockstep change**, because the string is consumed UI-side:

- The producer is `reventless-host-shell/public/config.json` (this repo).
- The consumer is in **reventless-ui**, which reads `authMode` to pick the auth flow. That comparison (whatever matches `"inmemory"`) must change to `"local"` in the UI repo, released, and the host-shell pin bumped to the new UI tag.
- Per the memory rules: edit sibling-repo code only with `pnpm link:on` active, **take the new UI version from its git tag** (never hand-bump / `lerna version` in the UI repo), and pin the host-shell to that exact tagged version.
- **Sequencing to avoid a broken window:** accept **both** `"inmemory"` and `"local"` in the UI comparison first (release that UI version, bump the pin), *then* flip the `config.json` string to `"local"` in this repo. That way neither repo is briefly pointing at a value the other doesn't understand. Once the dust settles, the UI can drop the `"inmemory"` alias.

### 7. In-flight references

A Backlog plan ([reventless-vscode-in-memory-platform-runner.md](../plans/Backlog/reventless-vscode-in-memory-platform-runner.md)) and several done plans name the package. Done plans are historical and can stay; the Backlog plan should be renamed/edited since it describes future work.

---

## Opportunities

1. **Name the real axis: local vs aws.** Post-rename, the mental model becomes `reventless-local` (dev/single-node) vs `reventless-aws` (cloud), with `Backend.Memory | Backend.Sqlite` as a *sub*-choice inside local. This is a cleaner teaching story and matches `REVENTLESS_LOCAL_BACKEND`.
2. **Headroom for more backends.** "Local" doesn't promise a storage tech, so adding LMDB, a file-snapshot, or a Postgres-on-localhost arm later needs no further rename.
3. **Better first impression for persistence.** New users currently have to *discover* that the "in-memory" platform can persist. `reventless-local` + a `Backend` doc surfaces SQLite as a first-class, expected capability.
4. **Forcing function to finish the SQLite story.** TaskBucket is still a no-op stub and not every adapter has a Sqlite arm. The rename is a natural moment to audit "what does 'local with persistence' actually guarantee?" and document the gaps (or close them).
5. **A meaningful, documented adapter convention (now adopted — OQ1).** With the always-in-process adapters normalized, the suffix becomes a *signal*: seeing `_InMemory` in the `ReventlessLocal` namespace tells a reader "this is a persisted surface with a `_Sqlite` twin." Worth writing into the conventions doc so future adapters follow it (add a `_Sqlite` arm → suffix both; in-process only → no suffix).

---

## Risks & costs (summary)

| Risk | Severity | Mitigation |
|---|---|---|
| Over-broad rename destroys `_InMemory`/`_Sqlite` distinction | **High if done literally** | Keep `_InMemory` on the 3 persisted surfaces; drop it only where no `_Sqlite` twin exists (decided OQ1) |
| Suffix-drop name collision inside the package (e.g. `Bus`, `CommandTopicChannel`) | Medium | Check `components/` + interfaces for intra-package clashes before dropping; namespace isolates from core |
| Private-registry rename = new package + deprecation dance | Medium | Deprecate old, continue version line at `3.0.0-alpha.86` (OQ2), atomic `workspace:*` bump |
| Large mechanical diff (namespace + suffix drop + ~485 regenerated `.res.mjs`) | Medium | Single focused commit; rely on zero-warning build gate |
| Golden-fixture + docs-route breakage | Medium | Regenerate goldens; add docs redirects |
| Cross-repo `authMode` lockstep (decided OQ3) | Medium | UI accepts both `"inmemory"`+`"local"` first → bump pin → flip `config.json` → later drop alias |
| Git history loss | Low | `git mv` + remember the `git add` of edited-moved files |

---

## Recommended approach (phased)

The decisions below resolve the original open questions; the sequence reflects them.

1. **UI first (OQ3 lockstep, part 1):** in **reventless-ui**, widen the `authMode` check to accept **both** `"inmemory"` and `"local"`. Release it (version from git tag), bump the host-shell pin to that tag. This makes the later `config.json` flip safe.
2. **Core rename — package + namespace + dirs** in one branch: `git mv reventless/reventless-in-memory reventless/reventless-local`; update `rescript.json` `namespace` → `ReventlessLocal`; set `package.json` `name` → `@reventlessdev/reventless-local` and `version` → `3.0.0-alpha.86` (OQ2); update the 27 config files; find-and-replace `ReventlessInMemory` → `ReventlessLocal`; rebuild; re-commit regenerated `.res.mjs`.
3. **Suffix normalization (OQ1):** keep `_InMemory` on the 3 persisted storage surfaces; `git mv` the ~21 always-in-process adapters to their bare names (table above) and fix every reference (incl. `InMemory_Bus.T` → `Bus.T` in the `_Sqlite` functor signatures). Check for intra-package name collisions before each drop.
4. **Rename example platform dirs/packages** (`platform-in-memory` → `platform-local`, package names `…-platform-local`) and **regenerate golden fixtures** so `ForwardGoldenTest.res` stays green.
5. **Sweep docs vocabulary** ("in-memory platform" → "local platform"), rename docs-site folder `docs-infrastructure/in-memory/` → `local/` + D2 dirs, add redirects, update README + CLAUDE.md + the conventions table (and record the new suffix convention).
6. **Flip the UI string (OQ3, part 2):** change `config.json` `"authMode"` → `"local"` in this repo, now that the UI understands both.
7. **Publishing:** publish `@reventlessdev/reventless-local` at `3.0.0-alpha.86`; **deprecate** `@reventlessdev/reventless-in-memory` with a pointer to the new name (supersede, don't rename-in-place — GitHub Packages dist-tags are unreliable). Call out the rename in release notes.
8. **Cleanup (follow-up):** once the new UI tag is everywhere, drop the `"inmemory"` alias from the UI auth check.
9. **Verify:** full `pnpm run build` (zero warnings) + `pnpm test` + golden tests green before merge.

> **Timing (the one remaining judgement call):** because this is a deliberate breaking rename, bundle it as a **standalone rename PR** rather than mixing it into a feature change — the diff is large but purely mechanical, so a clean isolated PR is easiest to review and revert. The alpha line tolerates the break.

---

## Decisions (resolved open questions)

| # | Question | Decision |
|---|---|---|
| OQ1 | Identity-only, or also normalize always-in-process adapter suffixes? | **Also normalize** — drop `_InMemory` where no `_Sqlite` twin exists; keep it on the 3 persisted surfaces. Document the convention. |
| OQ2 | Fresh `0.x` or continue the version line? | **Continue** — start `reventless-local` at `3.0.0-alpha.86`. |
| OQ3 | Rename the UI `authMode` string now, or defer? | **Rename** `"inmemory"` → `"local"`, via the dual-accept lockstep sequence above. |
| OQ4 | Bundle into a release vs standalone PR? | **Standalone mechanical rename PR** (recommendation; not yet confirmed by user). |
