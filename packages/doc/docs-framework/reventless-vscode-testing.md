# Testing the `reventless-vscode` extension

This guide walks through manually verifying the `@reventlessdev/reventless-vscode` extension end-to-end: CLI sanity, dev-host launch, discovery, run, failure rendering, cancellation, configuration, file watching, and VSIX packaging.

The extension is pure glue between the `reventless-gwt --format=vscode` NDJSON stream and VS Code's [Testing API](https://code.visualstudio.com/api/extension-guides/testing). Most bugs show up first in the CLI output; exercising the CLI directly before involving VS Code is the fastest way to narrow down where a failure lives.

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

In the dev-host window: **File → Open Folder** → pick `reventless/reventless-gwt/`.

The default `reventlessGwt.roots` config is `["tests"]`, which resolves to `reventless-gwt/tests/` relative to the workspace. The CLI resolver walks up from the workspace folder looking for `node_modules/.bin/reventless-gwt` and finds it at the monorepo root.

---

## 5. Verify discovery

Open the **Testing** panel (flask icon in the sidebar). Expect:

- 8 file nodes (one per `*GwtTest.res.mjs` in `tests/`).
- Under each file, one or more suites.
- 41 total test leaves.

These counts should match `pnpm --filter @reventlessdev/reventless-gwt test`.

Clicking a file, suite, or test row opens the underlying `.res` **source** (not the compiled `.res.mjs`) at the combinator's line. The CLI derives the `.res` sibling from the discovered `.res.mjs` path and grep-scans for the quoted label — `test("collect: …"` places the cursor on that line. Renamed or hand-written `.mjs` files with no sibling `.res` fall back to the compiled path.

If the panel is empty, check **Output → Log (Extension Host)** for the `reventless-gwt: discovery failed` message — most commonly an unresolved `reventless-gwt` binary (see §8) or a ReScript compile error that prevented `.res.mjs` from being produced.

---

## 6. Run tests

- **Run all** — click the double-play icon at the top of the Testing panel. All 41 should go green.
- **Run one** — hover a single test → click the play icon. Only that test runs (VS Code passes the test's id to the extension, which forwards it as `--filter`).
- **Run a subtree** — click the play icon on a file or suite row. Only descendants run.

All three paths use the CLI's substring-match `--filter`, so the ids emitted at discovery time MUST match the ids emitted at run time. (This was a real bug fixed in Stage 8 — both sides now prefix with the absolute file path.)

---

## 7. Verify failure rendering

Temporarily break a test. For example in [`reventless/reventless-gwt/tests/StateChangeSliceGwtTest.res`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/reventless-gwt/tests/StateChangeSliceGwtTest.res), change an expected event's field. Rebuild:

```bash
pnpm --filter @reventlessdev/reventless-gwt run build
```

The file watcher should trigger re-discovery within ~250 ms. Click run on the broken test. Expect:

- A red X on the failed test.
- Clicking the failure opens a **diff view** whose `expected` and `actual` panes are rendered in **ReScript syntax** (e.g. `CategoryAdded({categoryId: "c1", name: "Electronics"})`) — not `{TAG: "CategoryAdded", _0: {...}}`.
- **Cmd+Click** on the failure location jumps to the *slice implementation* (`hint.locus`), not the test file. This is the whole point of Stage 2's `Hint` module threading through to `FormatterVsCode.messagePayload`.

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

In the dev host: **Settings → Extensions → Reventless GWT**.

- **`reventlessGwt.cliPath`** — set to the absolute path of the CLI launcher, e.g. `/abs/path/to/reventless-core/reventless/reventless-gwt/bin/reventless-gwt.mjs`. Refresh the Testing panel (circular arrow icon). Discovery should still work. Clear the setting to fall back to the `node_modules/.bin` walk-up.
- **`reventlessGwt.roots`** — set to a narrow value, e.g. `["tests/QueryGwtTest.res.mjs"]`. Refresh. The tree should shrink to just that file. Restore to `["tests"]` afterward.

---

## 10. Verify file watching

With the Testing panel visible, `touch` any `*GwtTest.res.mjs` in `tests/`, or edit and rebuild a `*GwtTest.res`. Within ~250 ms the tree should refresh (this is the debounce in the extension's `FileSystemWatcher` handler). If the edit adds or removes a test, the tree reflects it.

The watcher glob is `**/*{_GWT,GwtTest}.res.mjs`, so changes to non-compiled sources don't trigger it — you must rebuild.

---

## 11. Known gotchas

- **`node_modules/.bin/reventless-gwt` missing.** The extension's walk-up fails, falls back to PATH, which usually isn't set. Fix: `pnpm install` at the monorepo root, or set `reventlessGwt.cliPath` explicitly.
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

Marketplace publishing (icon, publisher registration, `vsce publish`) is deferred — see Stage 8 deviations in [`docs/plans/reventless-gwt.md`](https://github.com/ReventlessDev/reventless-core/blob/main/docs/plans/reventless-gwt.md).

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
- **Output → Log (Extension Host)** (dev host) or **Output → Reventless GWT** (main VS Code) has no `reventless-gwt: discovery failed` lines. If it does, the CLI resolution broke — see §11's first bullet.

---

## 14. Continuous run (watch mode)

The `Run` profile declares `supportsContinuousRun: true`, so the Testing panel shows a flask-with-eye toggle next to the normal double-play. Click it to keep a run alive: the extension executes the initial selection once, then re-executes the same selection every time a compiled `.res.mjs` under the watched roots changes.

### Two-process setup

Continuous run fires on `.res.mjs` changes, not `.res` saves. Run the ReScript watcher in a side terminal so edits produce fresh compiled output:

```bash
pnpm --filter @reventlessdev/reventless-gwt run start
# or from inside the affected package:
pnpm run start   # equivalent to `rescript build -w`
```

The extension deliberately doesn't launch its own `rescript build -w` — fighting a watcher the user already has running is out of scope, and `rescript` serialises builds by default so racing two watchers causes lockfile contention.

### What gets re-run

Whatever the user originally selected — the extension replays `request.include` verbatim:

- **Run all** → every discovered test re-runs.
- **Run a file / suite / single test** → only that subtree re-runs.

No dependency-graph awareness: editing one slice re-runs every selected test, not just the affected ones. A full suite completes in well under a second today (≈250 ms for 30 tests), so the added work isn't a concern.

### How cancellation works

Each iteration starts with `killInFlight()` — if a previous iteration is still mid-flight when a new `.res.mjs` change arrives, the extension sends `SIGINT` to the child CLI. The CLI's `Cancellation` module (§7 of the plan, Stage 7) traps the signal, marks in-flight tests as `Skip{reason:"cancelled"}`, and exits cleanly. The new iteration then spawns a fresh process.

Toggling the flask-eye icon off fires `token.onCancellationRequested`, which disposes the `FileSystemWatcher` subscription and kills any live process. Subsequent file edits are ignored until continuous run is re-enabled.

### Debounce and rapid edits

File-change events are debounced at 250 ms. A burst of saves (e.g. `:wa` across several files) collapses into a single re-run. If saves arrive while an iteration is already running, the extension marks a `pending` re-run and fires it as soon as the current iteration finishes — at most one queued behind the live one.

### Known limitations

- **Single debounce window.** A save that arrives 250 ms after a still-running iteration triggers a second iteration immediately after the first finishes, even if the first was already up-to-date with all changes. No practical impact — the extra run costs ≈ one suite duration.
- **Reload Window cancels continuous mode.** Expected: the token fires as part of window teardown. Re-enable the flask-eye after reload.
- **Closing the test panel does not cancel.** VS Code keeps the run profile alive; only the flask-eye toggle actually tears down the watcher.

---

## References

- [`docs/plans/reventless-gwt.md`](https://github.com/ReventlessDev/reventless-core/blob/main/docs/plans/reventless-gwt.md) — Stage 8 action log and deferred items.
- [`docs/analysis/given-when-then-specifications.md`](https://github.com/ReventlessDev/reventless-core/blob/main/docs/analysis/given-when-then-specifications.md) §3.3 — `--format=vscode` event table and the thin-extension example.
- [VS Code Testing API](https://code.visualstudio.com/api/extension-guides/testing) — `TestController`, `TestItem`, `TestMessage`, `TestRun`.
- [`packages/reventless-vscode/src/extension.ts`](https://github.com/ReventlessDev/reventless-core/blob/main/packages/reventless-vscode/src/extension.ts) — the extension source (~260 lines).
