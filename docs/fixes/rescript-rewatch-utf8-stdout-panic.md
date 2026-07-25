# ReScript 12.3.0: rewatch build panics on non-UTF-8 / multibyte bytes in compiler output

## Symptom

A full (clean) `rescript build` of `reventless-host-shell` panics the Rust build
orchestrator (rewatch) before any module output is written:

```
Parsed 400 source files

thread '<unnamed>' panicked at src/build/compile.rs:791:18:
stdout should be non-null: Utf8Error { valid_up_to: 2779, error_len: Some(2) }
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
```

- **Reproducible**, not flaky: identical `valid_up_to` offset across runs for a
  given source set.
- The `valid_up_to` offset *moves* when the triggering source bytes change
  (e.g. stripping non-ASCII chars from a few files relocated the panic from
  `valid_up_to: 2779` to `valid_up_to: 259`) — confirming it is a generic
  decode failure, not one specific file.
- **Incremental** builds are unaffected (they don't recompile the module whose
  warning/error message carries the offending bytes), which is why day-to-day
  dev and the deployed bundle were unharmed — only a clean full build crashes.

## Root cause

The panic message `stdout should be non-null` is an `.expect(...)` on a strict
`std::str::from_utf8` in rewatch's `compile_file()`
(`rewatch/src/build/compile.rs`):

```rust
let err = std::str::from_utf8(&x.stderr)
    .expect("stdout should be non-null")   // panics on invalid UTF-8
    .to_string();
```

`from_utf8` returns `Err(Utf8Error)` when the captured compiler output is not
valid UTF-8 at a read boundary; `.expect()` then panics. The compiler (`bsc`)
emits warning/error messages that quote source context, and that context can
contain non-ASCII characters (em dash `—`, middle dot `·`, multiplication sign
`×`, section sign `§`, box-drawing `─`, etc.). When such a byte sequence lands
at the boundary of a captured chunk, strict decoding fails and the whole build
aborts.

Notes:
- The `.expect("stdout should be non-null")` message is **mislabeled** — it
  decodes `x.stderr`, not stdout.
- The sibling path `execute_post_build_command()` in the same file already uses
  the safe `String::from_utf8_lossy(...)`; only `compile_file()` still uses the
  strict form.

## This is a known *class* of bug — but this occurrence is unfixed

- The ReScript team previously fixed the analogous case:
  **"Rewatch: fix non-unicode stderr"** — PR
  [rescript-lang/rescript#7613](https://github.com/rescript-lang/rescript/pull/7613),
  released in **12.0.0-beta.2**.
- However, the strict `from_utf8().expect(...)` in `compile_file()` is still
  present on **`master`** (checked against
  [`rewatch/src/build/compile.rs`](https://github.com/rescript-lang/rescript/blob/master/rewatch/src/build/compile.rs)),
  so it ships in **every release including 12.3.0**.
- No matching open issue found in
  [rescript-lang/rescript issues](https://github.com/rescript-lang/rescript/issues)
  — this specific code path appears unreported.

## Affected / not affected

- **rescript 12.2.0**: builds `reventless-host-shell` fine (it was last built
  there on 2026-06-17). The panic is a **12.3.0 regression** for this path.
- **rescript 12.3.0**: full clean build of `reventless-host-shell` panics.
- **No fixed release exists** — npm `rescript` has only `12.3.0-beta.1` and
  `12.3.0` in the 12.3 line; `12.2.0` is the last good one.
- `reventless-core` (incl. `reventless-aws`) and `reventless-ui` base/routes
  build clean at 12.3.0 — their captured output happens not to split a
  multibyte char at a read boundary. Only `reventless-host-shell` trips it.

## Proposed upstream fix (one line)

Mirror PR #7613 / `execute_post_build_command` — use lossy decoding so invalid
bytes become the replacement char instead of aborting the build:

```diff
--- a/rewatch/src/build/compile.rs
+++ b/rewatch/src/build/compile.rs
@@ compile_file()
-    let err = std::str::from_utf8(&x.stderr)
-        .expect("stdout should be non-null")
-        .to_string();
+    let err = String::from_utf8_lossy(&x.stderr).to_string();
```

(While here, the same file's other strict `from_utf8` captures of subprocess
stdout/stderr should be audited and converted to `from_utf8_lossy` for
consistency with `execute_post_build_command`.)

## Upstream issue draft

> **Title:** rewatch build panics (`Utf8Error`) on non-UTF-8 bytes in compiler
> output — `compile_file()` uses strict `from_utf8().expect(...)`
>
> **Version:** 12.3.0 (also present on `master`). Works on 12.2.0.
>
> **What happens:** A clean `rescript build` aborts with:
> ```
> thread '<unnamed>' panicked at src/build/compile.rs:791:18:
> stdout should be non-null: Utf8Error { valid_up_to: <N>, error_len: Some(<k>) }
> ```
>
> **Cause:** `compile_file()` decodes captured compiler output with
> `std::str::from_utf8(&x.stderr).expect("stdout should be non-null")`. When a
> warning/error message quotes source containing a non-ASCII character
> (`— · × § ─` …) and that byte sequence falls at a capture boundary, strict
> decoding returns `Err` and `.expect()` panics. Incremental builds avoid it
> (the offending module isn't recompiled).
>
> **Note:** the `.expect` message says "stdout" but decodes `stderr`. The
> sibling `execute_post_build_command()` already uses `from_utf8_lossy`; this
> path was missed. The same class was fixed before in #7613 (12.0.0-beta.2).
>
> **Fix:** replace with `String::from_utf8_lossy(&x.stderr).to_string()`.
>
> **Repro:** any project whose compiler messages include a non-ASCII char near a
> capture boundary; deterministic per source set.

## Impact on this monorepo / workarounds

- The user-facing bug this surfaced from (the cross-plugin product multi-select)
  was fixed independently via an **incremental** rebuild of
  `RegisterFragments.res.mjs` — see the AutoUI `generateFragments` signature
  realignment. host-shell development and deploy are not blocked; only clean
  full builds are.
- **CI guard scoping:** a "clean rebuild → fail on tracked `.res.mjs` diff"
  check is viable today for `reventless-core` + `reventless-ui` base/routes
  (they rebuild idempotently at 12.3.0). For `reventless-host-shell`, substitute
  a targeted check — *rebuild host-shell whenever `AutoUI.generateFragments`'s
  signature changes* — until rescript ships the fix above, since a clean full
  build cannot complete on 12.3.0.
- Revisit a full host-shell clean-build guard once a patched rescript (>12.3.0
  with the `from_utf8_lossy` fix) is released, or if the monorepo standardizes
  back on 12.2.0.

## Interaction with the test-`.res.mjs` untracking workstream (2026-07-25)

`docs/plans/untrack-test-mjs-via-root-build-emission.md` adds `pinned-dependencies` so a
single root build emits every package's test outputs. This **increases exposure to this
panic** in two ways: (1) pinned packages are force-rebuilt on every root build, and the plan's
verification is a clean `rm -rf lib + build` — the maximal warning-surfacing full build; (2)
pinning newly compiles the `type: dev` **test** sources of `core`/`spec`/`interop`, and test
files carry the non-ASCII (em-dashes / box-drawing in GWT descriptions) that trips the decode —
so `reventless-core` could panic where it currently builds clean.

**Recommended companion fix:** run full/clean builds via `rescript-legacy build` (the ninja
path, immune; `console-web` already does). `pinned-dependencies` is originally a bsb feature,
so it is fully supported under legacy — the switch de-risks both the panic and the pinning
spike simultaneously. Keep rewatch (`rescript build`) for incremental `-w` dev only. The
durable fix remains the one-line upstream `from_utf8_lossy` patch above — **still worth filing
as an issue**, as no matching report was found.
