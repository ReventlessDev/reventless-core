# Testing the `reventless-vscode` extension

This guide walks through manually verifying the `@reventlessdev/reventless-vscode` extension end-to-end: CLI sanity, dev-host launch, discovery, run, failure rendering, cancellation, configuration, file watching, and VSIX packaging.

The extension is pure glue between the `reventless-gwt --format=vscode` NDJSON stream and VS Code's [Testing API](https://code.visualstudio.com/api/extension-guides/testing). Most bugs show up first in the CLI output; exercising the CLI directly before involving VS Code is the fastest way to narrow down where a failure lives.

---

## 0. Zero-config usage — any app (e.g. `online-shop-hybrid`)

The extension drives a long-lived `reventless-gwt watch --format=vscode` per workspace folder. That one CLI process **auto-discovers every GWT test**, **owns a `rescript build -w` per package**, and **re-runs the affected tests on every recompile** — so for any Reventless app you just:

1. **Open the folder** (single plugin *or* a multi-plugin example root like `examples/online-shop-hybrid`).
2. That's it. The Testing panel populates, the status bar shows `$(sync~spin) reventless: building` → `$(check) reventless`, and saving any `.res` / `_GWT.res` re-runs its tests.

No `reventless.roots`, no `.vscode/` files, no side-terminal `rescript build -w`:

- **Roots are auto-discovered** — with no path argument the CLI scans the whole workspace-folder subtree (pruning `node_modules`/`lib`/`.git`/`.history`). `reventless.roots` remains only as an override.
- **Builds are CLI-managed** — the CLI derives the package set (each `package.json` with a `start` script that owns tests) and spawns one watcher per package. If you already run `pnpm run start` for a package, the CLI detects its live `lib/rescript.lock` and **adopts** it instead of double-spawning (a "Reventless — Build" channel line marks it `[external]`).
- **Multi-plugin examples work in one window** — `online-shop-hybrid` yields watchers for `catalog`, `ordering`, `platform-local` automatically.

The status bar and a **"Reventless — Build"** output channel surface build progress and any compile errors. A one-shot **Run** profile (the play icon) is still available for run-on-click / CI-style single runs, backed by `reventless-gwt run`.

> The numbered sections below are the manual end-to-end *verification* walkthrough (CLI sanity → dev host → discovery → run → failure rendering → cancellation → packaging). They predate the `watch`-driven flow above and still hold for verifying the CLI directly; where they describe setting `reventless.roots` or running `rescript build -w` in a side terminal, that is now handled automatically.

---

## UI surface map — where to find every component

Everything the extension renders, by location in the VS Code window. Use this as a manual dev-host checklist: each entry says **where** it appears, **what** it looks like, **how** to make it show, and the **provider** in [`src/extension.ts`](https://github.com/ReventlessDev/reventless-core/blob/main/packages/reventless-vscode/src/extension.ts) that produces it.

VS Code geography terms used below: **Activity Bar** = far-left vertical icon strip; **Primary Side Bar** = the panel that opens when you click an Activity Bar icon; **Panel** = the bottom area (Output / Problems / Terminal); **Status Bar** = the bottom strip; **editor** = the code area (CodeLens is clickable text above a line; the Code Action lightbulb is at the start of a line or via `Cmd+.`).

```text
VS Code window  (letters point to the sections below)

Activity Bar (far-left strip)
  Reventless icon  -> opens the Components view  [B]
  flask icon       -> opens the Testing view     [C]

Primary Side Bar (opens from an Activity Bar icon)
  COMPONENTS .................. Plugin > kind > component > files   [B]
                               (component files = spec + body + tests)
  TESTING:
    Test Explorer ............ file > suite > test                 [C]
    REVENTLESS WATCH ......... one row per package + build state   [C]

Editor
  Run / coverage CodeLens, quick-fix lightbulb                     [E]
  failure expected/actual diff                                     [F]

Status Bar (bottom-left)
  one folded health line, e.g. "Reventless - 312 pass 2 fail"      [D]

Panel > Output (channel dropdown)
  "Reventless"  and  "Reventless - Build"                          [G]
```

### A. Activity Bar — the Reventless icon
- **Where:** far-left icon strip, a dedicated **Reventless** container (icon `media/reventless.svg`).
- **Shows:** clicking it opens the **Components** view (below) in the Primary Side Bar.
- **Trigger:** always present once the extension activates (activation fires on a workspace containing `*_GWT.res` / `*GwtTest.res` / `reventless-gwt.config.json`).
- **Source:** `contributes.viewsContainers.activitybar` in `package.json`.

### B. Primary Side Bar → **Components** view
- **Where:** click the Reventless Activity Bar icon → the view titled **COMPONENTS**.
- **Shows:** a tree **Plugin → kind group → component → files**. Plugin nodes (the short package dir name, e.g. `catalog`) use `$(package)`; kind groups (`Aggregate`, `StateChangeSlice`, `ReadModel`, …) use `$(symbol-namespace)`; components use `$(symbol-method)`. Under each component, its **source files** list first — the spec (marked `spec`) then body/implementation files like `*_Behavior.res` / `*_Mappings.res` — followed by its **GWT test files**. Each file leaf uses the **same glyph as its category toggle** (`media/cat-spec.svg` / `cat-behavior.svg` / `cat-gwt.svg`), so the tree and the show/hide buttons match.
- **Completeness indicator:** an incomplete component shows the description `⚠ missing <parts>` (any of `spec`, `behavior`, `GWT`) with a `$(warning)` icon; a complete one shows no description. The check is kind-aware: `Task` expects only a spec; `Extension` / `ExtensionPoint` expect a body file + a GWT (no separate spec). Source files always list regardless.
- **Authoring:** the title bar's **`＋`** creates a component (and there's a remove action); right-clicking a plugin / chapter / component row offers create-in-scope, rename, move-to-chapter, and delete — scaffolding the spec / body / GWT files and updating workspace wiring. A just-created row appears **optimistically** before the watch re-reflects.
- **Domain badges:** rows carry inline signals beside the name — a **codegen / synthesize** status badge (forward/backward codegen progress), a **dead-code** `⚠` when a produced event has no consumer, and, on a DCB consumed slice, a **`◂ N consumed · K unknown`** badge (`K` = consumed-event arms naming no known producer; expand the `consumed events` group for the per-arm diagnostic + a rename quick-fix).
- **Click-through:** clicking a component opens its **spec file** (or first test if no spec); clicking any file leaf opens that file.
- **Category filters:** three title-bar toggles show/hide each file category, each with its own glyph (custom `media/cat-*.svg`: document = **spec**, `</>` = **behavior**, flask = **GWT**). All on by default; hiding a category strikes its glyph through (and dims it) and removes those files from every component. Commands `reventless.showSpec` / `hideSpec` (and behavior / gwt), also in the Command Palette.
- **Flat / tree toggle:** `$(list-flat)` / `$(list-tree)` switches between the full tree (`plugin → kind → component → files`) and a **flat** view — `plugin → files`, every file directly under its plugin (grouped by component, spec → behavior → GWT), with no kind-group or component level. Commands `reventless.componentsAsFlat` / `componentsAsTree`.
- **Expand / collapse:** the title bar has **Expand All** (`$(expand-all)`) and the native **Collapse All** (`$(collapse-all)`, from `showCollapseAll`); each **plugin** row also has inline **Expand** / **Collapse** (`$(expand-all)` / `$(collapse-all)`) for just that plugin's subtree.
- **Trigger:** populates after the watch session's `components` + discovery `item` events arrive (a second or two after opening the folder). Untested components appear because the inventory scans `src/`, not just files that have tests.
- **Overflow:** the title actions collapse into the `⋯` "More Actions" menu when the view is too narrow to show them all as icons.
- **Source:** `ComponentTreeProvider`, view id `reventless.components`.

### C. Testing view (flask icon) — two things live here
Open it via the **flask icon** in the Activity Bar (or **View → Testing**).

1. **Test Explorer tree** — the main content.
   - **Shows:** `plugin → file → describe suite → test` leaves per discovered `*_GWT.res`, with pass ✓ / fail ✗ / skip markers and durations as the watch re-runs. The top level groups files by their owning plugin (package); running a plugin node runs that whole package (`--filter <package dir>`). After a run, each **file** row's description reads `<run time> · <path>` (e.g. `8ms · catalog/tests/…/Product_GWT.res.mjs`) — the aggregate time of that file's tests, before the path.
   - **Run controls:** the double-play at the top runs all; hovering a row reveals a per-row play (one-shot `run --filter`).
   - **Show-only-failed toggle:** a `$(filter)` button (title-bar action) flips the tree between **all tests** and **only failing tests** (`$(filter-filled)` when active). It prunes the tree to failed leaves + their ancestors and restores on toggle-off, reusing the same items so results persist. When the filter is on but **nothing is failing**, it shows a single `✓ No failing tests` row (so the filter visibly took effect, without VS Code's misleading "No tests found / install extensions" placeholder). Commands: `reventless.showOnlyFailed` / `reventless.showAllTests` (also in the Command Palette). The same toggle is what the status-bar click drives (D).
   - **Expand all:** an `$(expand-all)` button (`reventless.expandAll`) opens every branch — the native tree only auto-expands to a fixed depth. *Collapse all* has **no title icon**: VS Code's test explorer doesn't give the tree focus on a title-icon click, so `list.collapseAll` had no reliable target; the `reventless.collapseAll` command remains in the Command Palette (where the tree keeps focus) and collapsing nodes by hand always works.
   - **Auto-expand failures:** after each run, every failing test is revealed (its branch expanded) so failures are never hidden under a collapsed node.
   - These title-bar actions live **only on the Test Explorer** (not the Watch view). When the side bar is too narrow to fit them as icons, VS Code collapses them into the title bar's `⋯` overflow menu automatically.
   - **Source:** `TestController` `reventless-gwt` ("Reventless GWT") + `WatchSession`; the filter is `TestTree` (membership rebuilt from a retained model).

2. **Reventless Watch view** — a separate collapsible view **below** the test tree (it's registered into the Testing container, not the Activity Bar). It's a **per-package build dashboard**: it shows which packages the CLI watch session is compiling (or has adopted from your own `rescript build -w`) and their live build state.
   - **Where:** scroll to the bottom of the Testing side bar → the view titled **REVENTLESS WATCH**.
   - **Shows:** one row per package, labelled with the short package name, and its build state — `starting…` `$(circle-large-outline)`, `building` `$(sync)`, `built` `$(check)`, `build failed` `$(error)`, `external (adopted)` `$(link)`. Tooltip carries the npm name, path, and build command.
   - **Row click:** reveals that package in the Explorer (a per-row action).
   - **Title actions:** **Restart Watch** (`$(debug-restart)`), **Stop**/**Start Watch** (`$(debug-stop)` / `$(debug-start)`, toggled by state), and **Open Build Log** (`$(output)`, shared channel). Restart kills and respawns the watch session(s) — re-running discovery and re-spawning/re-adopting the per-package build watchers; use it after adding a package, when a watcher is stuck, or to take over a package you'd been running yourself. Stop tears everything down (frees CPU) and Start brings it back. All three are also in the Command Palette. (Test-tree actions — filter / expand — live on the Test Explorer, not here.)
   - **Trigger:** appears after the `packages` event. Force `external` by running your own `rescript build -w` for a package before opening the folder.
   - **Source:** `WatchTreeProvider`, view id `reventless.watch`; title actions via `contributes.menus.view/title`.
   - **Note:** the build *log* is a single shared channel, so "Open Build Log" shows the same output regardless of which package you came from — the per-package signal is the state icon/label, not separate logs.

### D. Status Bar — workspace health
- **Where:** **bottom-left** of the window (left-aligned, priority 100).
- **Shows:** one folded summary, e.g. `$(check) Reventless · 312✓ 2✗`, `$(sync~spin) Reventless · building catalog`, `$(error) … · build failed`, `… · watch stopped`, with a `N⊘` segment when tests are skipped. Hover tooltip: *"Reventless watch session"*.
- **Red background:** the whole item turns red (`statusBarItem.errorBackground`) on an error state — **failing tests**, a build failure, or a watcher that died unexpectedly. An in-progress build suppresses the red (spinner instead), and a clean run clears it.
- **Watch off:** after a manual **Stop Watch**, the item reads `$(circle-slash) Reventless · watch off` (not red — it's intentional) until you **Start Watch** again.
- **Click target:** clicking the item jumps to the **Test Explorer** (C) and reveals a test there. If **any test is failing**, it switches the explorer to *show-only-failed* and reveals the first failure; otherwise it switches to *show all* and reveals the first test. Command: `reventless.statusBarClick`.
- **Trigger:** updates on every `build*` / `runEnd`. In a multi-folder workspace the tallies **sum** into this one item.
- **Source:** `WatchRegistry.statusText()` (unit-tested in [`test/watchRegistry.test.mjs`](https://github.com/ReventlessDev/reventless-core/blob/main/packages/reventless-vscode/test/watchRegistry.test.mjs)).

### E. Editor — CodeLenses and the quick-fix
- **Run CodeLens:** open any `*_GWT.res` → a clickable **`▷ Run`** sits **above each `test(…)` / `describe(…)`**. Clicking runs just that id via `run --filter`. Source: `GwtCodeLensProvider`.
- **Coverage CodeLens:** open a component **spec** `.res` file (e.g. `Aggregate/Product.res`) → at the **very top (line 1)** a lens reads **`$(beaker) N GWT`** or **`$(warning) No GWT tests`**. It is package-scoped and skips body files (`_Behavior`, `_Projections`, …) and GWT files. Source: `SpecCoverageCodeLensProvider`.
- **Apply-expected quick-fix:** in a `*_GWT.res` with a **failing `thenEvents([…])`** assertion, put the cursor on the failing test block → the **💡 lightbulb** (line start, or `Cmd+.`) offers **"Replace expected with actual (thenEvents)"**. It appears only for `EventsMismatch`; not for singular `thenEvent`, `thenError`, or state mismatches. Source: `ApplyExpectedProvider`.

### F. Test failure detail — the expected/actual diff
- **Where:** when a test fails, an inline red decoration appears on the assertion line in the editor (the message + a peek), and the same is reachable from the **Test Results** panel (**View → Testing → Show Test Output**, or click the failed leaf).
- **Shows:** the hint message plus **Expected** / **Actual** panes rendered in **ReScript syntax** (e.g. `ProductsNotAvailable({missing: ["p1"]})`). `Cmd+Click` on the failure location jumps to the slice locus, not the test file.
- **Source:** `FormatterVsCode.messagePayload` → `toTestMessage`.

### G. Panel → Output channels
- **Where:** **Panel** (bottom) → **Output** tab → the channel dropdown (top-right of the Output view).
- **Channels:** **"Reventless"** (diagnostic log — spawn lines, protocol-mismatch notices, discover/run summaries) and **"Reventless — Build"** (`[ok]` / `[FAIL]` / `[external]` per package, with build-error bodies).
- **Source:** `vscode.window.createOutputChannel(...)`; the Build channel is also what **Open Build Log** focuses.

### H. Command Palette
- **Where:** `Cmd+Shift+P`, all under the **Reventless:** prefix.
- **Visible:** Open Build Log; Show Only / All Failed Tests; Expand / Collapse All Tests; Components as Flat / Tree; Show / Hide Spec / Behavior / GWT; Expand All Components; Restart / Stop / Start Watch. (These are the same commands behind the view-title icons — the palette is the always-available path, and the reliable one for *Collapse All Tests*.)
- **Hidden** (`when: false`, invoked from the UI only): `reventless.runTest` (Run CodeLens), `reventless.statusBarClick` (status bar), `reventless.expandPlugin` / `collapsePlugin` (per-plugin inline actions — they need the row as an argument).

### I. Event Graph webview
- **Where:** the **Components** view title bar → the **graph** icon (type-hierarchy), or **Reventless: Show Event Graph** in the Command Palette. Opens a webview panel titled **Reventless — Event Graph**. A `platformEvents` row's inline **Show Event in Graph** and a `readModels` row's **Show Read Model in Graph** open it focused on that node.
- **Shows:** the Event-Modeling flow as a D2 diagram — commands (blue) → write-sides (Aggregate / StateChangeSlice, yellow) → events (orange) → read models / state views (green), plus automation slices (purple), translation slices (rose, with `IN` / `OUT` corner badges), and the extension-point ↔ extension cross-plugin chain (teal hexagons). Nodes group into **per-plugin containers**, sub-grouped by **chapter**. An `API` corner badge marks API-exposed commands / read models.
- **Focus scoping:** click a node to focus it; the toolbar toggles **Scoped** (the kind-aware neighbourhood, bounded at the EP / Extension connectors) vs **Full flow** (the whole connected component), with **✕ Full graph** to clear. Clicking a **plugin** or **chapter** container scopes to it (and selects the matching Components row); ⌘/Ctrl-click a node opens its source.
- **Legend:** a collapsible panel (top-right) listing every node kind + arrow type with a colour swatch, a checkbox per type, and a master **Show all** — hide a type to declutter (e.g. hide the dashed DCB-read overlay). Toggles are active only for types present in the current view; deselecting everything still leaves the plugin boxes.
- **External systems:** a translation slice that names an `externalSystem` draws a rose dashed **external box** outside its plugin, with a directional dashed boundary arrow (the anti-corruption boundary).
- **Authoring:** right-click a node / container / empty canvas for create-component, create-chapter, and new-plugin actions (plus rename / move-to-chapter / delete on component nodes) — the same engine as the Components view's create flow.
- **Pan/zoom:** scroll to zoom (toward the cursor), drag to pan, double-click or `0` to fit, `+` / `-` to zoom.
- **Trigger:** uses the watch session's `graph` event (the live reflected model); when the platform isn't running it falls back to a disk-derived synthetic graph, and to a raw-D2 text view if the `d2` binary isn't on `PATH`.
- **Source:** `DomainGraphD2.res` (pure D2 builder) + `renderGraph` in `extension.ts`; `media/graphView.{js,css}`.

### J. Context Map webview
- **Where:** the **Components** view title bar → the **globe** icon, or **Reventless: Show Context Map**. Panel titled **Reventless — Context Map**.
- **Shows:** the whole platform at the **plugin-composition** layer — every plugin as a bounded-context box (even element-less ones), its **extension points** (provided ports) and **extensions** (required ports) as interlocking hexagon icons, its inbound/outbound translation slices, and the dashed **cross-plugin links** wiring an extension to the extension point it targets. Command / event / read-model detail is omitted — that's the Event Graph's job.
- **External systems:** grouped into one **"External Systems" lane** pinned above the contexts, each with a dashed boundary link to its translation slice.
- **Always full:** never scoped — clicking a port only **highlights** it (and selects the matching Components row, preserving pan/zoom); clicking a plugin box selects that plugin. Uses the same legend panel as the Event Graph (port kinds + the cross-plugin link).
- **Source:** `ContextMapD2.res` + `renderContextMap` in `extension.ts`; `media/contextMapView.{js,css}`.

### Now built (the earlier "not yet" list)
The features this guide once listed as unbuilt have shipped: **domain dead-code** → component-row `⚠` warnings + `Problems` diagnostics; the **Event Graph** + **Context Map** D2 webviews (sections I/J above); **watch-session control** (Restart / Stop / Start); and a **`buildFail` → `Problems` fallback** when the `rescript-vscode` LSP is absent. Compile errors you see in **Problems** still come from the LSP, not this extension.

---

## 1. Build prerequisites

From the monorepo root:

```bash
cd /path/to/reventless-core
pnpm --filter @reventlessdev/reventless-gwt run build       # compiles CLI + test fixtures
pnpm --filter @reventlessdev/reventless-vscode run build    # compiles out/extension.js
```

Re-run both whenever you edit the respective sources. The extension only re-discovers when compiled `.res.mjs` files change.

---

## 2. CLI sanity (no VS Code involved)

Before launching the dev host, confirm the CLI emits well-formed NDJSON for both invocation modes:

```bash
node reventless/reventless-gwt/bin/reventless-gwt.mjs discover --format=vscode reventless/reventless-gwt/tests/ | head -3
node reventless/reventless-gwt/bin/reventless-gwt.mjs run --format=vscode reventless/reventless-gwt/tests/ | tail -3
```

Expected:

- `discover` starts with `{"event":"discoverStart"}` and ends with `{"event":"discoverEnd","total":N}`.
- `run` ends with `{"event":"runEnd","passed":N,"failed":0,"skipped":0,...}`.

If either is missing or malformed the extension cannot possibly work — fix the CLI first.

---

## 3. Launch the Extension Development Host

Two options.

**Option A — Install from location** (simplest, no debugger):

1. In VS Code, **Cmd+Shift+P** → **Developer: Install Extension from Location…**
2. Pick `packages/reventless-vscode/`.
3. **Developer: Reload Window**.

**Option B — F5 dev host** (recommended when developing the extension):

1. Open `packages/reventless-vscode/` as the root folder in VS Code.
2. Add `.vscode/launch.json` if not present:
   ```json
   {
     "version": "0.2.0",
     "configurations": [
       {
         "name": "Run Extension",
         "type": "extensionHost",
         "request": "launch",
         "args": ["--extensionDevelopmentPath=${workspaceFolder}"],
         "outFiles": ["${workspaceFolder}/out/**/*.js"],
         "preLaunchTask": "npm: build"
       }
     ]
   }
   ```
3. F5 → a second VS Code window opens with the extension loaded and debugger attached.

---

## 4. Open a test workspace in the dev host

In the dev-host window: **File → Open Folder** → pick a Reventless app (e.g. `examples/online-shop-hybrid/`, or a single plugin like `reventless/reventless-gwt/`).

`reventless.roots` now defaults to **empty**: the watch session auto-discovers every GWT test across the workspace-folder subtree, so no config is needed. The CLI resolver walks up from the workspace folder looking for `node_modules/.bin/reventless-gwt` and finds it at the monorepo root.

---

## 5. Verify discovery

Open the **Testing** panel (flask icon in the sidebar). The tree is **plugin → file → suite → test**:

- One **plugin** node per package that owns tests (e.g. `catalog`, `ordering`).
- Under each, a **file** node per `*_GWT.res` (after a run its row shows `<time> · <path>`).
- Under each file, one or more **suites**, then **test** leaves.

The total test count should match `pnpm --filter @reventlessdev/reventless-gwt test` (or the per-package `pnpm test`).

Clicking a file, suite, or test row opens the underlying `.res` **source** (not the compiled `.res.mjs`) at the combinator's line. The CLI derives the `.res` sibling from the discovered `.res.mjs` path and grep-scans for the quoted label — `test("collect: …"` places the cursor on that line. Renamed or hand-written `.mjs` files with no sibling `.res` fall back to the compiled path.

If the panel is empty, check **Output → Log (Extension Host)** for the `reventless-gwt: discovery failed` message — most commonly an unresolved `reventless-gwt` binary (see §8) or a ReScript compile error that prevented `.res.mjs` from being produced.

---

## 6. Run tests

- **Run all** — click the double-play icon at the top of the Testing panel; all should go green.
- **Run one** — hover a single test → click the play icon. Only that test runs (VS Code passes the test's id to the extension, which forwards it as `--filter`).
- **Run a subtree** — click the play icon on a plugin, file, or suite row. Only descendants run (a plugin node runs the whole package via `--filter <package dir>`).
- **Continuous** — you usually don't need to click Run at all: the watch session re-runs affected tests automatically on every recompile (§14).

All three paths use the CLI's substring-match `--filter`, so the ids emitted at discovery time MUST match the ids emitted at run time. (This was a real bug — both sides now prefix with the absolute file path.)

---

## 7. Verify failure rendering

Temporarily break a test. For example in [`reventless/reventless-gwt/tests/StateChangeSliceGwtTest.res`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/reventless-gwt/tests/StateChangeSliceGwtTest.res), change an expected event's field. Rebuild:

```bash
pnpm --filter @reventlessdev/reventless-gwt run build
```

The file watcher should trigger re-discovery within ~250 ms. Click run on the broken test. Expect:

- A red X on the failed test.
- Clicking the failure opens a **diff view** whose `expected` and `actual` panes are rendered in **ReScript syntax** (e.g. `CategoryAdded({categoryId: "c1", name: "Electronics"})`) — not `{TAG: "CategoryAdded", _0: {...}}`.
- **Cmd+Click** on the failure location jumps to the *slice implementation* (`hint.locus`), not the test file. This is the whole point of the `Hint` module threading through to `FormatterVsCode.messagePayload`.

Revert the break after verifying.

---

## 8. Verify cancellation

Temporarily slow a test body — simplest path is to add an `await new Promise(r => setTimeout(r, 5000))` at the start of one test (do this in `.res` and rebuild, or edit the compiled `.res.mjs` directly for a one-off check). Start the run, then click the stop icon.

Expected:

- The in-flight test marks as skipped.
- The CLI child process exits promptly.
- No zombie processes in `ps`.

Mechanism: the extension forwards `token.onCancellationRequested` → `proc.kill('SIGINT')`. The CLI's `Cancellation.res` flag-polls between tests and tags anything in-flight as `Skip{reason:"cancelled"}` before emitting `runEnd`.

---

## 9. Verify configuration overrides

In the dev host: **Settings → Extensions → Reventless**.

- **`reventless.cliPath`** — set to the absolute path of the CLI launcher, e.g. `/abs/path/to/reventless-core/reventless/reventless-gwt/bin/reventless-gwt.mjs`. Restart the watch (Watch view → Restart). Discovery should still work. Clear the setting to fall back to the `node_modules/.bin` walk-up.
- **`reventless.roots`** — set to a narrow value, e.g. `["catalog/tests"]`. Restart the watch. The tree should shrink to just that subtree. Clear it to return to full auto-discovery.

---

## 10. Verify file watching

File watching is now owned by the **CLI `watch` session**, not the extension: the CLI runs a `rescript build -w` per package (or adopts yours), and on every recompile it re-discovers and re-runs the affected tests, streaming the updates. So just **edit and save a `.res`** — once it compiles, the tree refreshes and the affected tests re-run automatically (no rebuild step, no side terminal). Adding or removing a test is reflected on the next discovery cycle.

---

## 11. Known gotchas

- **`node_modules/.bin/reventless-gwt` missing.** The extension's walk-up fails, falls back to PATH, which usually isn't set. Fix: `pnpm install` at the monorepo root, or set `reventless.cliPath` explicitly.
- **Stale `.res.mjs`.** Editing `.res` sources without rebuilding means the extension still sees the old test set. Always rebuild the gwt package after source edits.
- **Extension source edits.** See §13 for the update flow in both the dev host and a VSIX-installed copy.
- **Multiple workspace folders.** The extension currently uses `vscode.workspace.workspaceFolders?.[0]` — only the first folder is scanned. Multi-root workspaces need a follow-up.
- **Framework log lines in CLI output.** The CLI launcher defaults `LOG_LEVEL=silent` so `Logger.fromEnv()` produces no output — Info/Debug logs would otherwise interleave with NDJSON on stdout and break JSON parsing. To re-enable framework logs (debugging a slice), run with an explicit override: `LOG_LEVEL=info reventless-gwt run …`. Levels: `silent` | `error` | `warn` | `info` | `debug`.

---

## 12. Package as VSIX (dogfood in real VS Code)

To exit the dev host and install into your primary VS Code:

```bash
cd packages/reventless-vscode
pnpm dlx vsce package --no-dependencies -o reventless-vscode.vsix
```

Then in your main VS Code: **Extensions: Install from VSIX…** → pick the generated `.vsix`. Uninstall via **Extensions** panel → right-click → **Uninstall** when you're done.

Marketplace publishing (icon, publisher registration, `vsce publish`) is deferred.

---

## 13. Updating the extension

Which rebuild + reload you need depends on what you edited and how the extension is loaded.

### You edited `src/extension.ts` (dev host — §3)

```bash
pnpm --filter @reventlessdev/reventless-vscode run build
```

Then in the dev host window: **Cmd+Shift+P → Developer: Reload Window**. The build writes `out/extension.js`; Reload Window re-reads it. No need to exit and relaunch.

If you're using **Option B (F5)**, the `preLaunchTask: "npm: build"` in `.vscode/launch.json` runs the build for you — just stop the debug session (Shift+F5) and press F5 again.

### You edited `package.json` (dev host)

Changes under `contributes.*` (commands, configuration, menus) are picked up by **Developer: Reload Window**. Changes to `activationEvents` or `main` sometimes aren't — if a new command or configuration key doesn't appear, fully close and relaunch the dev host (Option B: stop and F5 again; Option A: close the window, reload the main window, reopen the dev host).

### You edited the CLI or a GWT DSL (`reventless/reventless-gwt/src/**`)

```bash
pnpm --filter @reventlessdev/reventless-gwt run build
```

The extension's file watcher (§10) sees the changed `.res.mjs` files and re-runs discovery within ~250 ms. No Reload Window needed — the extension code itself hasn't changed.

### You edited both (most common)

```bash
pnpm --filter @reventlessdev/reventless-gwt run build && \
  pnpm --filter @reventlessdev/reventless-vscode run build
```

Then Reload Window in the dev host.

### You installed a VSIX in your main VS Code (§12)

VSIX-installed extensions do **not** hot-reload on `out/extension.js` changes — they live at `~/.vscode/extensions/…` and are read at install time. Every update needs a repackage + reinstall:

1. Rebuild the CLI (if changed) and the extension — same commands as above.
2. Repackage:
   ```bash
   cd packages/reventless-vscode
   pnpm dlx vsce package --no-dependencies -o reventless-vscode.vsix
   ```
3. In main VS Code: **Cmd+Shift+P → Extensions: Install from VSIX…** → pick the new `.vsix`. Accept the "Already installed — update?" prompt.
4. **Developer: Reload Window** in every VS Code window that had the old extension active.

If the version in `package.json` didn't change, some versions of VS Code refuse to reinstall silently. Bump the `version` field (`0.1.0` → `0.1.1`) or uninstall first via **Extensions** panel → right-click → **Uninstall**.

### Sanity check after any update

- Testing panel refreshes; discovered test count matches `pnpm --filter @reventlessdev/reventless-gwt test`.
- **Output → Log (Extension Host)** (dev host) or **Output → Reventless** (main VS Code) has no spawn/discovery error lines. If it does, the CLI resolution broke — see §11's first bullet.

---

## 14. Continuous run (watch session)

Continuous running is **the default** — there's no flask-eye toggle to enable. On activation the extension spawns one long-lived `reventless-gwt watch --format=vscode` per workspace folder, and the **CLI** is the engine: it discovers tests, owns a `rescript build -w` per package (or adopts one you're already running), and on every recompile re-discovers and re-runs the affected tests, streaming the results. The extension just renders the stream onto the Testing API.

So the flow is simply: **edit a `.res`, save it** → the CLI rebuilds → the tree refreshes and the affected tests re-run. No side terminal, no `.res.mjs` watching in the extension, no manual rebuild.

### Controlling the session

The **Reventless Watch** view (§C) drives the session:

- **Restart** — kill and respawn the watcher(s); re-runs discovery and re-spawns/re-adopts the build watchers. Use after adding a package, when a watcher is stuck, or to take over a package you'd been building yourself.
- **Stop / Start** — tear the session down (frees CPU; status bar shows `watch off`) and bring it back.

### Build ownership (spawn-or-adopt)

The CLI spawns `pnpm run start` (`rescript build -w`) per test-owning package, unless it detects a live watcher already holding that package's `lib/watch.lock` / `lib/rescript.lock` — then it **adopts** it (Watch row shows `external (adopted)`, `$(link)`) rather than racing a second watcher over the build lock.

### Cancellation / teardown

Stopping, restarting, removing a workspace folder, or closing the window disposes the session: the extension sends `SIGINT` to the CLI, whose `Cancellation` handler tears down every spawned `rescript build -w` (via `ProcessManager.killAll`, `SIGTERM`) before exiting — no orphaned compilers.

### Known limitations

- **Build watchers are spawned once**, right after the initial discovery — not re-evaluated mid-session. Add a package, or stop your own external watcher for an adopted package, then **Restart** to pick it up.
- **No respawn on death** — a watcher that exits isn't auto-restarted; **Restart** the session.
- **Reload Window** disposes and re-creates the sessions (expected).

---

## References

- [`docs/analysis/given-when-then-specifications.md`](https://github.com/ReventlessDev/reventless-core/blob/main/docs/analysis/given-when-then-specifications.md) — `--format=vscode` event table and the thin-extension example.
- [VS Code Testing API](https://code.visualstudio.com/api/extension-guides/testing) — `TestController`, `TestItem`, `TestMessage`, `TestRun`.
- [`packages/reventless-vscode/src/extension.ts`](https://github.com/ReventlessDev/reventless-core/blob/main/packages/reventless-vscode/src/extension.ts) — the extension source (~260 lines).
