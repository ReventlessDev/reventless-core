# Plan: the Jest bindings take glennsl suites unchanged

**Status.** Planned 2026-10-12. Nothing built.

**In plain words.** [`@reventlessdev/rescript-jest`](../../rescript/jest/) binds Jest's globals
directly: every `expect` runs at its line, and an `async` test body is awaited. Test suites
written against `@glennsl/rescript-jest` cannot use it without a rewrite, because the two APIs
differ in names and in how an assertion works. This plan adds a second module to the package,
`Jest`, with glennsl's names and types but this package's behaviour. A suite then moves over by
changing its dependency, with no edits to its test files.

**Why now.** Under ReScript 12, glennsl 0.13.1 (its latest release, 2025-12-07) does not
register async tests properly. Its `testPromise`, `testAsync`, `testAll` and `testAllPromise` call
an external bound to the global `test`. ReScript 12 emits that call as a bare `test(…)`, and in the
compiled module the name resolves to glennsl's own `let test` wrapper, which runs the callback and
discards what it returns. Jest gets a synchronous test that passes on its first tick, and the
promise's assertions run after Jest has moved on. If one fails, or a timer it leaves behind
rejects, the error surfaces as an unhandled rejection after the run, or not at all. A suite on
glennsl can patch the externals to `@scope("globalThis")` as a stopgap. The defect that made this
package necessary in the first place stays: an assertion that isn't returned is never checked.

**Goal.** A suite on glennsl swaps `@glennsl/rescript-jest` for `@reventlessdev/rescript-jest` in
`package.json` and `rescript.json` and compiles with no source edits. Every assertion it makes
then runs, and every async test is awaited.

**Non-goals.** Changing [`JestGlobals`](../../rescript/jest/src/JestGlobals.res), which stays
the API for new tests. Binding glennsl's whole surface on day one: snapshots, `MockJs` and
`JestJs` come in only when a consumer needs them. Upgrading Jest itself, covered in
[§5](#5-jest-30).

---

## 1. What glennsl suites use

Measured across the suites on glennsl in two app repositories on 2026-10-12: 221 test files.

| glennsl name | Uses |
|---|---|
| `test` | 3,261 |
| `toEqual` / `toBe` | 2,882 / 585 |
| `describe` | 900 |
| `testPromise` | 313 |
| `testAsync` | 33 |
| `afterEach` / `beforeEach` | 34 / 11 |
| `pass` / `fail` | 29 / 22 |
| `Jest.useFakeTimers` / `Jest.advanceTimersByTime` | 3 / 12 |
| `toThrow`, `toContain`, `toContainString`, `Skip.test` | 13 together |

Every file starts with `open Jest`. Some also `open Expect`, the module glennsl nests in `Jest`.

## 2. The module

`src/Jest.res` with a `src/Jest.resi` that copies glennsl's signatures for the names it covers.
The package has `namespace: false`, so the module is the top-level `Jest` a suite already opens.

- **`assertion`** is an abstract type over `unit`. Each matcher calls Jest's `expect` at once,
  throws on failure, and returns an `assertion`. A test that returns its last assertion still
  type-checks, and the assertions before it now count as well.
- **`test`** takes `unit => assertion` and registers a synchronous test.
- **`testPromise`** takes `unit => promise<assertion>` and passes the promise to Jest, which
  awaits it. `~timeout` maps onto Jest's third argument.
- **`testAsync`** gives the callback a `done`-style function and maps it onto Jest's `done`.
- **`testAll` / `testAllPromise`** register one test per input, named as glennsl names them.
- **`describe`, `beforeEach`, `afterEach`, `beforeAll`, `afterAll`** and their `Async` and
  `Promise` variants keep glennsl's names and signatures.
- **`Skip`, `Only`, `Todo`** mirror glennsl's submodules.
- **`pass`** is an `assertion` that checks nothing. **`fail(message)`** throws.
- **`Expect`** holds `expect`, `not_` and the matchers in [§1](#1-what-glennsl-suites-use), plus
  the rest of glennsl's `Expect` that maps one-to-one onto a Jest matcher. glennsl's `partial`
  types stay, so `expect(x)->not_->toBe(y)` keeps compiling.
- **`Jest`** (nested, as in glennsl) holds the timer functions: `useFakeTimers`,
  `useRealTimers`, `advanceTimersByTime`, `runAllTimers`, `runOnlyPendingTimers`,
  `setSystemTime`.

Every global is bound with `@scope("globalThis")`, as `JestGlobals` already is, so a local
binding of the same name can't capture it.

## 3. The behaviour change a suite will see

The only difference a suite should notice is the one this plan exists for: assertions that were
never checked now run.

- An assertion that isn't the test's return value now runs. If it fails, the test fails at that
  line instead of passing.
- An async test is awaited. A test that only passed because its body never finished now fails or
  times out.
- An error thrown after a test completes now lands in that test, not in an unhandled rejection
  after the run.

Each newly failing test is a test that was passing without checking anything. The consumer fixes
those, not this package.

## 4. Steps

### J1: the module

`Jest.res` and `Jest.resi` as in [§2](#2-the-module).

**Exit:** a glennsl suite compiles against it with only its dependency changed.

### J2: the package gets tests

The package has none today. Add a Jest project to it, with one test per promise in [§3](#3-the-behaviour-change-a-suite-will-see).
Some of these tests have to fail when the run passes, so they run as a child Jest whose result is
checked:

- a failing assertion in the middle of a test fails it;
- a `testPromise` whose assertion fails after a delay fails;
- a `testAsync` that never calls `done` times out;
- `Skip.test` doesn't run, and `Todo.test` reports as a todo.

**Exit:** each item above fails exactly when it should.

### J3: release

Publish the package locally. A push to `alpha` starts the full release and deploy.

**Exit:** the version is on npm, and its README names `Jest` as the way to move a glennsl suite
over.

## 5. Jest 30

This repository and its consumers run Jest 29.7.0. Jest 30.5.2 is current (2026-09-18).
Jest 30 needs Node 18.14 or later (we run 22), and `jest-environment-jsdom` moves from jsdom 20 to
jsdom 26. The globals this package binds are unchanged in 30, so the bindings don't depend on the
Jest major. J2's test project runs on 29 and on 30, and the package declares a peer of
`jest: ^29.7.0 || ^30.0.0`. Moving this repository's own suites to 30 is a separate piece of work.

## 6. Open questions

1. Should `Jest` emit a warning when a suite returns `pass`, which now checks nothing?
   **Recommendation:** no. glennsl's `pass` never checked anything either, and a warning on 29
   call sites tells nobody anything new.
2. Should `MockJs` and `JestJs` be in J1? **Recommendation:** no. Neither is used by the suites
   measured in [§1](#1-what-glennsl-suites-use). Add them when a consumer brings a call site.
