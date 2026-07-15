# Plan: Package-internal dedup (five structural steps)

**Status**: Proposed (2026-07-15). Split out of [quality-performance-hardening.md](quality-performance-hardening.md) Phase C4 — the remaining dedup items each carry enough risk or need a distinct decision that they don't belong in a single "cleanup" commit. Each is its own scoped, independently-verifiable step.

**Not in scope (rejected from C4):**
- **`Util_Adapter`/`Util_AdapterRuntime` merge** — rejected. Both are Pulumi-entangled (`Util_Adapter` carries `Pulumi.Output.all`/`apply` throughout; `Util_AdapterRuntime` is the leaner variant). The split is a deliberate runtime/deploy seam; merging risks reintroducing deploy-time Pulumi into the runtime graph — the exact regression the `*_Ops` split fixed. No safe dedup here.
- **One `Util_` naming convention** — cosmetic, near-zero value; dropped.

Each step below lands with its own tests and a clean zero-warning build; verify the full monorepo suite before committing.

---

## Step 1 — Unify admin GraphQL schema registration (`reventless-local`)

**Where:** `reventless/reventless-local/src/Platform.res`.

**Current state:** the inner resolver registration is already factored into `registerAdminItemsAndIndexResolvers(~queryResolvers, ~live)` (≈ line 1267). But it is called from **three** distinct registration blocks that each wrap it with their own admin-schema setup and differ subtly:
- **domain single-server** path (≈ line 1683, `~live=true`),
- **split-mode** path routing admin schema to `PlatformGraphQL_Server` vs `DomainGraphQL_Server` (≈ line 1964, `~live=false`),
- **live redeploy** path (≈ line 2177, `~live=true`).

**The risk:** this is a **deploy-path** file, and the three blocks have **drifted** — so "unify" is not mechanical: it means choosing the *canonical* admin-registration behavior and proving the two non-canonical blocks were equivalent (or intentionally different). It cannot be smoke-tested from a unit test alone.

**Approach:**
1. Diff the three blocks line-by-line; document every divergence and classify each as (a) accidental drift or (b) intentional per-topology difference (domain vs split vs redeploy).
2. Extract a single `registerAdminSchema(~target, ~live, ~splitMode, …)` that takes the topology differences as parameters, so the three call sites collapse to one call with different args.
3. Preserve behavior exactly for the (b) cases; fix the (a) drift toward the canonical block and note which block was canonical and why.
4. **Verify** with a live local-platform smoke on both topologies (single-server and split mode) — admin Plugin queries/mutations resolve, plugin (de)registration works — plus the existing `Platform_ComponentDefinitionsApiTest` / admin suites. Full monorepo green.

**Done when:** one `registerAdminSchema`, three thin call sites, drift resolved with a documented canonical choice, both topologies verified live.

---

## Step 2 — Namespace interop's spec-colliding module names (`reventless-interop`)

**Where:** `reventless/reventless-interop/src/components/`.

**Current state:** interop declares 20 component modules whose names shadow the framework's spec/core modules of the same name — `Aggregate`, `ReadModel`, `StateChangeSlice`, `StateViewSlice`, `Plugin`, `Counter`, `Task`, `ExtensionPoint`, `EventLog`, `DcbEventLog`, `CommandGenerator`, `CommandTopic`, `EventTopic`, `EventCollector`, `EventMapper`, `QueryDb`, `AutomationSlice`, `InboundTranslationSlice`, `OutboundTranslationSlice`. A file that `open`s both `ReventlessInterop` and the core/spec namespace gets ambiguous references and must fully-qualify — and the collision makes cross-reading error-prone (`Aggregate.resolvedOutputs` vs `Aggregate.T`).

**The risk:** `reventless-interop` is **published**; renaming exported modules is an API change for any external consumer, and there are many internal references (`ReventlessInterop.Aggregate.resolvedOutputsSchema`, etc.) across core/aws/layer-builder.

**Approach — pick one:**
- **(A) Rename the modules** with a disambiguating suffix (e.g. `Aggregate` → `AggregateOutputs`, mirroring that every interop component is the `resolvedOutputs`/`outputs` counterpart). Update all `ReventlessInterop.<Name>` references repo-wide. Lowest ambiguity, highest churn, breaking for external consumers (major bump).
- **(B) Leave the file/module names, add a namespacing convention** — keep them under an explicit inner module (`ReventlessInterop.Outputs.Aggregate`) so callers opt into the qualifier. Less churn, still a reference-path change.

Recommend **(A)** with the `…Outputs` suffix (names then say what they are), gated on confirming the published surface can take a major bump. Whichever is chosen, do it as one mechanical rename commit with a full build + monorepo suite.

**Done when:** no interop component module shares a bare name with a spec/core module; all references updated; build + suite green; version-bump implication noted in the commit.

---

## Step 3 — Fold `FormatterJson`/`FormatterVsCode` onto the shared mismatch vocabulary + optional JUnit change (`reventless-gwt`)

**Where:** `reventless/reventless-gwt/src/Formatter*.res`.

**Current state:** `FormatterHuman` and `FormatterTap` already render mismatches through the shared `MismatchRender.normalize(m): {kind, fields}` vocabulary. `FormatterJson.mismatchJson` (and `FormatterVsCode`) still use a **separate**, richer surface — a structured `{type, payload, rendered}` shape plus `fieldDiff` (`Diff.diffArrays`/`Diff.diff` → `Diff.toJsonArray`). JUnit (`Outcome.format`) uses yet another (JSON-based) rendering.

**Why it's its own step (not a drive-by):**
- The JSON/VsCode `{type,payload,rendered}` + `fieldDiff` shape is a **genuinely different surface** than the Human/TAP string normalization — it carries machine-diff data the string formatters don't. Folding requires *extending* the shared vocabulary (a `fieldDiff` carrier + structured payload) rather than collapsing onto the string form; done naively it is lossy.
- Switching **JUnit** from JSON-based `Outcome.format` to the `RenderRescript` path is an **intentional output change**, not behavior-preserving — it must land as an explicit, reviewable golden diff.

**Approach:**
1. Extend `MismatchRender` (or a sibling) with a structured variant that carries both the rendered strings *and* the `fieldDiff` payload the JSON/VsCode emitters need.
2. Reimplement `FormatterJson.mismatchJson` and `FormatterVsCode` on top of it; the existing `FormatterGoldenTest` (10 kinds × formatters) must stay **byte-for-byte green** to prove preservation.
3. **Separately** (own commit): flip JUnit to the shared rendering; regenerate its goldens as an explicit diff.

**Done when:** all four/five emitters share one mismatch vocabulary, JSON/VsCode goldens byte-identical, JUnit change (if taken) is an isolated reviewed golden diff.

---

## Step 4 — gwt test-DSL vocabulary alignment (`reventless-gwt`) — needs naming sign-off

**Where:** `reventless/reventless-gwt/src/*_GWT.res` DSLs and the example `_GWT` tests that consume them.

**Current state — user-facing inconsistencies:**
- Command step spelled `whenCmd` / `whenCommand` / `whenSourceCmd` across DSLs.
- Five spellings for "nothing emitted" (`thenNoEvent`, `thenNothing`, …) — enumerate and pick one.
- `test` is sync in some DSL modules, promise-with-timeout in others.
- `AggregateT` is missing `todo` (present on the other flavours).

**The risk:** these are **user-facing DSL identifiers**. Renaming them touches every example `_GWT.res` test and any downstream test suite; generic or non-idiomatic names get rejected. **Requires explicit naming sign-off before implementing.**

**Approach:**
1. Inventory every DSL surface identifier across the `*_GWT` modules; build the canonical-name table (command step, no-event assertion, `test` shape, `todo`).
2. Get the canonical names approved.
3. Land the rename with deprecation-free aliases only if needed; update all example `_GWT.res` in lockstep; run every example plugin's GWT suite through the real runner.

**Done when:** one spelling per concept across all DSLs, `AggregateT.todo` present, `test` shape consistent, all example GWT suites green through the runner.

---

## Step 5 — Remove the dead Platform-wide `silent` flag (`reventless-local` + `reventless-core` + `reventless-aws`)

**Where:** the `silent` config flag threaded through the platform builders.

**Current state:** `silent` is a `MakeWithConfig` `Config` field, not a LocalBus-local concern. It appears in: `reventless-local/src/Platform.res` (the `Config` module type `let silent: bool`, the two bus `Impl({… silent …})` wirings, the `Make` default, and a diagnostic **log line** that prints it), `reventless-core/src/admin/Platform_Admin.res` (its `Config` `let silent: bool`), `reventless-aws/src/Platform.res` (`let silent = false`), and **7 `MakeWithConfig` call sites** that each pass `let silent = …`.

**It is provably dead:** nothing ever *reads* it to change behavior. Its sole nominal consumer was `LocalBus`, which discarded it (no warning site exists to suppress); the only other use is the log line echoing it. So removal is a **zero-behavior-change** cleanup.

**Why it's its own step (a LocalBus-only removal is a trap):** dropping `silent` from `LocalBus`'s `BusConfig` alone compiles — because the field becomes an *ignored extra* on the inline bus config — but leaves `silent` still declared, threaded, and logged across all three Platforms and their callers (a misleading half-removed state; attempted and reverted 2026-07-15). The real removal touches a **public `MakeWithConfig` signature** across local/core/aws + every caller.

**Approach:**
1. Remove `let silent: bool` from the `Config` module types (local `Platform`, core `Platform_Admin`) and the aws `Platform` default.
2. Remove the two `Impl` wirings, the `Make` default, and the `silent: …` field from the diagnostic log line.
3. Update all 7 `MakeWithConfig` call sites (src + tests + examples) to stop passing `silent`.
4. Also drop `MakeSilent` in `LocalBus` (hollow once `silent` is gone) and repoint its `EventTapTest` callers to `Make`.
5. **Verify** the full monorepo suite green across local/core/aws + examples, zero warnings.

**Done when:** no `silent` field on any platform config or caller; `MakeSilent` gone; suite green.

---

## Sequencing

Independent; recommended order by value/risk: **5 (silent-flag removal — mechanical, safe)** → **3 (formatter fold)** → **1 (admin registration)** → **2 (interop namespaces)** → **4 (DSL alignment, after naming sign-off)**. Step 4 is blocked on the naming decision; the others can proceed in any order. Step 5 is the lowest-risk (provably dead, zero behavior change) despite its cross-package reach.
