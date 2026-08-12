# Plan: one answer to "how loud is a test run"

**Status.** Planned — 2026-08-12, from a false failure: running the core suite
with `LOG_LEVEL=silent` — the convention one package already encodes — fails five
assertions in `LogFormatTest` with `SyntaxError: Unexpected end of JSON input`.

**Goal.** Every way of running the tests is equally quiet, and no test's result
depends on how loud the run is.

**Non-goal.** Changing what the framework logs, or `Logger`'s level vocabulary.
The defect is entirely in how the *test harness* configures it.

---

## §1 — What is inconsistent today

**There are two entry points, and they share nothing.**

- `pnpm test` runs the root `jest.config.js`, whose `projects` array covers every
  package. It passes `--silent` and sets no `LOG_LEVEL`.
- `pnpm test:unit` runs `pnpm -r run test --if-present`, i.e. each package's own
  `test` script. The root config is not involved.

**Of the eight packages with a test script, exactly one sets a level:**

| Package | `test` script sets `LOG_LEVEL` |
|---|---|
| `local` | `LOG_LEVEL=${LOG_LEVEL:-silent}` |
| `core`, `aws`, `gwt`, `spec`, `infra`, `interop`, `postgres` | no |

`local` is not arbitrary — it is the one package that needs it.
`reventless/local/src/Platform.res:18` calls
`EffectLogger.setDefaultMinLevel(Debug)` at module load, so anything importing
the local platform logs at Debug unless told otherwise. Someone hit the noise
there and fixed it *there*, which is why the convention exists in one place and
nowhere else.

**And the two silences are different mechanisms.** `jest --silent` suppresses the
*display* of console output; `LOG_LEVEL=silent` stops the log being *emitted* at
all (`reventless/core/src/util/Logger.res:213-222` — `Some("silent") => None`,
and `None ⇒ defaultMinLevel`, which is `Info`). The root run is quiet by the
first mechanism, `local` by the second, and the other seven packages are quiet by
neither when run through `test:unit`.

## §2 — Two problems, and conflating them breaks the build

It is tempting to read this as one problem — "the scripts disagree" — and fix it
by putting `LOG_LEVEL=${LOG_LEVEL:-silent}` in all eight. That change, made on
its own, **turns five green assertions red**.

`LogFormatTest`'s "JSON sink" block
(`reventless/core/tests/logger/LogFormatTest.res:174+`) captures `console.log`,
calls `EffectLogger.logInfo(...)`, and asserts that every captured record parses
as JSON and carries no ANSI escape. Under `LOG_LEVEL=silent` nothing is emitted,
so there is nothing to capture: `JSON.parse("")` throws, and `lines.length >= 1`
is false. Measured:

```
LOG_LEVEL=silent  => Tests: 5 failed, 17 passed, 22 total
LOG_LEVEL=info    => Tests: 22 passed, 22 total
```

So there are two problems, and the second is not caused by the first:

- **A — a test that asserts on log output must control the level itself.** This
  is a correctness bug in the test, live today, independent of any script.
- **B — per-package runs should be as quiet as the root run.** This is tidiness.

**A must land before B**, or B is the change that breaks the suite. That ordering
is the whole reason this is a plan rather than a one-line commit.

## §3 — Fix A: the test pins what it asserts on

`LogFormatTest` already does exactly this for the *sibling* setting. Line 10:

```rescript
NodeProcess.env->Dict.set("REVENTLESS_LOG_FORMAT", "text")
Reventless.AnsiStyle.reload()
```

with a comment explaining that a non-TTY sink would otherwise change the answer.
The file pins the log **format** so the ambient environment cannot decide the
result, and then leaves the log **level** — which governs whether there is any
output at all — to chance. Pinning the level is not a new idea being introduced
here; it is the existing idea applied to the variable it was missed on.

```rescript
NodeProcess.env->Dict.set("LOG_LEVEL", "info")
```

`Logger` reads `process.env.LOG_LEVEL` through a `@val external` on **every**
call (`Logger.res:211-212`, "Re-read per call"), so a file-scope assignment
takes effect for the whole file regardless of what the runner exported.

⚠️ **`EventTapTest` looks like the same case and is not — leave it alone.**
`reventless/local/tests/adapter/EventTapTest.res` also captures `console.log`,
but the lines it asserts on come from `LocalBus.emitEventTap`, which is a plain
`Console.log` and never passes through `Logger` (the source says so, and says
why: it must not perturb the subscriber-countdown delivery semantics). It is
already level-independent. Adding a level pin there would imply a dependency
that does not exist.

## §4 — Fix B: where the default belongs

Three candidate homes, and the survey rules two of them out.

**Not a fourth shared setup file.** There are already three `jest.setup.cjs` —
root, `reventless/core`, `reventless/aws` — and they have **already drifted**:
the root one carries a `structuredClone` polyfill that the other two lack. Note
`<rootDir>` in a per-package jest config resolves to that *package*, so
`core`'s `setupFiles: ["<rootDir>/jest.setup.cjs"]` is not the root file even
though it reads as though it were. Five packages (`gwt`, `spec`, `infra`,
`interop`, `postgres`) have no `setupFiles` at all, so this route also means
adding the key to five configs that currently have none. Consolidating those
three files is worth doing — it is a real duplication bug — but it is a
different plan, and doing it as a prerequisite here would hold a five-line fix
behind a refactor.

**Not the root config alone.** It would leave `test:unit` — the path that
actually runs the per-package scripts — exactly as noisy as it is now.

**The `test` script in each package, matching `local`'s existing form:**

```
LOG_LEVEL=${LOG_LEVEL:-silent} …
```

Seven small edits, in the file a developer looks at when they wonder how the
tests run. The `:-` default is load-bearing and must be copied verbatim: it keeps
`LOG_LEVEL=debug pnpm test` working, which is the reason anyone touches this
variable in the first place. Set unconditionally, it would take away the only
tool for diagnosing a failing test's log output.

Duplicating one string eight times is a real cost and is accepted here with open
eyes: the alternative costs five config additions plus a merge of three drifted
setup files, and the string is one a reader can see and understand in place.

## §5 — What this plan does not do

**It does not remove `jest --silent` from the root script.** The two mechanisms
overlap but are not equivalent: `LOG_LEVEL` governs the framework's own logger,
while `--silent` also catches `console.log` from dependencies and from tests
themselves. Dropping it would trade a quiet run for a partly quiet one.

**It does not lower `defaultMinLevel` for tests.** That ref is the framework's
runtime default and a platform tunable; bending it for the harness would make
tests exercise a configuration no deployment runs.

## §6 — Acceptance

- `LOG_LEVEL=silent pnpm test:unit` and `LOG_LEVEL=silent pnpm test` both pass —
  the invocation that fails today.
- `pnpm test:unit` with `LOG_LEVEL` unset produces no framework log lines from
  any package. This is the one to check per package rather than in aggregate: it
  is the assertion that catches the script the sweep missed, and the sweep
  covering seven files is exactly the kind that misses one.
- `LOG_LEVEL=debug pnpm test:unit` still produces debug output — the override
  survives.
- `LogFormatTest` passes under `silent`, `info`, `debug` and unset. Four runs,
  because the point of §3 is that the file no longer cares.

## §7 — Order of work

1. §3 — pin `LOG_LEVEL` in `LogFormatTest`. Verifiable alone, and it fixes a
   real latent bug whether or not step 2 ever happens.
2. §4 — add the `:-silent` default to the seven package scripts.
3. Re-run the §6 matrix.

Step 1 before step 2, for the reason §2 gives: reversed, step 2 is a commit that
breaks the suite and step 1 is a commit that "fixes" it, and the pair reads like
a bug and its repair rather than one intended change.

**Worth filing separately, found on the way:** the three `jest.setup.cjs` files
are near-copies that have already diverged on the `structuredClone` polyfill.
Whether that absence is deliberate or an oversight was not established here, and
it is not this plan's business — but a per-package run of the `aws` suite is not
loading a polyfill the root run gives it, which is its own latent difference
between the two entry points this plan is otherwise trying to make equivalent.
