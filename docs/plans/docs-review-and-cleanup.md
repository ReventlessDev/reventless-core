# Documentation Review & Cleanup Plan

## Summary

A review of all Docusaurus pages in `packages/doc/docs-app/` against the actual example code in `examples/` revealed several categories of issues. The most critical are a fully outdated aggregate walkthrough guide and stale `@decco` annotations scattered across component reference pages.

---

## Issues Found

### 1. Aggregate walkthrough guide uses obsolete behavior API (`aggregate-based-plugin.md`)

**File:** `packages/doc/docs-app/aggregate-based-plugin.md`  
**Lines:** 78–143

The guide teaches four separate behavior functions that no longer exist:

```rescript
// OUTDATED (docs)
let init: Behavior.init<state, Spec.event> = event => ...
let apply: Behavior.apply<state, Spec.event> = (state, event) => ...
let create: Behavior.create<...> = (command, context, error) => ...
let execute: Behavior.execute<...> = (state, command, ...) => ...
```

All current examples use the consolidated API:

```rescript
// CORRECT (examples/online-shop-aggregates/..., examples/online-shop-hybrid/...)
let initialState = ...
let evolve = (state, event) => ...
let decide = (state, command) => ...
```

The component reference `components/aggregate.md` already documents the correct API (lines 190–200) so the explanation text there is fine — only the walkthrough guide is wrong.

**Also in this file (line 248):** Uses `Reventless.Platform.T` — all actual plugin functors use `ReventlessInfra.Platform.T`.

**Fix:** Rewrite the behavior section and code examples. Replace `Reventless.Platform.T` with `ReventlessInfra.Platform.T`.

---

### 2. `plugin-system.md` uses outdated behavior API and inconsistent `Platform.T`

**File:** `packages/doc/docs-app/plugin-system.md`  
**Lines:** 90–136 (behavior code), 184 (Platform.T), 230 (Platform.T)

Same outdated `init`/`apply`/`create`/`execute` pattern in the behavior code examples.

Line 184 uses `Reventless.Platform.T`; line 230 correctly uses `ReventlessInfra.Platform.T`. Both should be `ReventlessInfra.Platform.T`.

**Fix:** Update behavior code examples and standardize `Platform.T` to `ReventlessInfra.Platform.T`.

---

### 3. `@decco` annotations in component reference pages

**All current code uses `@schema` (sury-ppx). `@decco` is a different PPX and not installed.**

Occurrences by file:

| File | Lines | Count |
|------|-------|-------|
| `components/aggregate.md` | 57, 62, 64, 67, 73, 80, 88 | 7 |
| `components/readmodel.md` | 49 | 1 |
| `components/extension.md` | 211, 216, 222 | 3 |
| `components/extensionpoint.md` | 87, 93, 100, 324 | 4 |

**Total: 15 occurrences across 4 files.**

**Fix:** Replace every `@decco` with `@schema` in these files. Verify surrounding code examples compile against current spec.

---

### 4. DCB walkthrough uses `model` parameter name inconsistently (`dcb-based-plugin.md`)

**File:** `packages/doc/docs-app/dcb-based-plugin.md`  
**Lines:** 113, 117, 120, 150, 153, 156, 186, 189, 192

The `evolve` and `decide` functions use `model` as the parameter name for state. All actual DCB examples use `state`. This is not a compilation error but creates confusion — readers will see `model` in the guide and `state` in the examples.

**Fix:** Rename parameter to `state` in all `evolve` and `decide` signatures in this file.

---

### 5. `aggregate.md` Spec code examples use `@decco` but explain `@schema`

**File:** `packages/doc/docs-app/components/aggregate.md`  
**Lines:** 57–88 (spec type block)

The component reference correctly explains `evolve`/`decide` in prose (lines 190–200) but the Spec code block on lines 57–88 still shows `@decco` on all type annotations. The code won't work as written.

(Covered partially under issue 3, but noted here as a split within the same file — upper section is wrong, lower section is correct.)

---

## Scope Not Affected (Verified Correct)

- `dcb-based-plugin.md` — uses `@schema` throughout, correct `ReventlessInfra.Platform.T`, correct `consumedEvent` in StateChangeSlice examples
- `components/statechangeslice.md`, `components/stateviewslice.md` — use `@schema` correctly
- `writing-unit-tests.md` — uses BehaviorTest DSL which is independent of the internal function names; does not describe `init`/`apply` directly
- `rescript-syntax.md` — uses `@schema` correctly

---

## Steps

- [x] **Step 1** — Fix `aggregate-based-plugin.md`:
  - Replace `init`/`apply`/`create`/`execute` behavior section (lines ~78–143) with `initialState`/`evolve`/`decide` pattern, aligned with `examples/online-shop-aggregates/catalog/src/Aggregate/`
  - Replace `Reventless.Platform.T` → `ReventlessInfra.Platform.T` (line 248)

- [x] **Step 2** — Fix `plugin-system.md`:
  - Update behavior code examples (lines ~90–136) to use `initialState`/`evolve`/`decide`
  - Replace `Reventless.Platform.T` → `ReventlessInfra.Platform.T` (line 184)

- [x] **Step 3** — Fix `@decco` → `@schema` in four component reference files:
  - `components/aggregate.md` (7 occurrences + 2 stale prose references to decco)
  - `components/readmodel.md` (1 occurrence)
  - `components/extension.md` (3 occurrences)
  - `components/extensionpoint.md` (4 occurrences)

- [x] **Step 4** — Fix `dcb-based-plugin.md` parameter naming:
  - Renamed `model` → `state` in all `evolve` and `decide` function signatures and bodies (CreateItem, RenameItem, DeleteItem slices)

- [ ] **Step 5** — Verify: build docs site locally (`cd packages/doc && npm run build`) and spot-check all edited pages render without errors

---

## References

- Correct behavior API: `examples/online-shop-aggregates/catalog/src/Aggregate/ProductBehavior.res`
- Correct DCB slice API: `examples/online-shop-hybrid/catalog/src/Product/StateChangeSlice/`
- Correct `Platform.T`: all `examples/**/Plugin/*Plugin.res` files
