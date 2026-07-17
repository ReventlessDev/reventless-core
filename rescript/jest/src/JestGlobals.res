// Direct bindings to Jest's global APIs.
//
// Why these exist instead of `@glennsl/rescript-jest`:
//
//   glennsl's assertion model is deferred by design — `expect |> toBe` builds a
//   value that only executes when it is *returned* from the test body (one
//   affirmed assertion per test). A mid-test assertion whose result is not
//   returned is silently inert: a forgotten `return` passes green. glennsl's
//   `testPromise` compounds this by wrapping the callback in
//   `() => { affirm(callback()); }`, discarding the returned Promise so Jest
//   treats an async test as synchronous and tests in a describe block race.
//
// This module binds straight to Jest's globals, giving:
//   * throwing `expect` — every assertion executes at its line, mid-test
//     assertions count, and a failure fails the test where it is written;
//   * native `async () => ...` test bodies that Jest actually awaits.
//
// Structure (this is the union of the five per-package modules it replaces):
//   * `module Runner` holds test-registration + lifecycle globals.
//   * `module Expect` holds the matchers.
//   * Both are also `include`d at the top level, so flat users can write
//     `open JestGlobals` and call `test` / `expect(x)->toBe(y)` directly.
//   Consumers that pair `open X` with `open X.Expect` should re-export `Runner`
//   and `Expect` separately (see the AsyncTest re-export modules) rather than
//   flattening both, to avoid a warning-44 `toBe` shadow.
//
// Surface notes:
//   * `test` registers an ASYNC test (callback returns a promise); `testSync`
//     registers a synchronous one. `testPromise` / `testAsync` are async aliases
//     of `test` kept for source compatibility.
//   * `beforeAll` / `afterAll` are SYNCHRONOUS; `beforeAllAsync` / `afterAllAsync`
//     take a promise-returning callback that Jest awaits.

type expectResult

// All globals are bound through `@scope("globalThis")` so they emit
// `globalThis.test(...)` / `globalThis.expect(...)` rather than a bare `test` /
// `expect`. A bare identifier would resolve to a local binding of the same name
// if a consumer module defines one (e.g. reventless-gwt's JestBind has its own
// `let test`); the explicit scope makes these immune to such shadowing.
module Runner = {
  // Async test — Jest awaits the returned promise before starting the next test.
  @scope("globalThis") @val external test: (string, unit => promise<unit>) => unit = "test"
  // Synchronous test — callback returns unit.
  @scope("globalThis") @val external testSync: (string, unit => unit) => unit = "test"
  // Async alias of `test`.
  @scope("globalThis") @val external testPromise: (string, unit => promise<unit>) => unit = "test"
  // Async alias of `test`.
  @scope("globalThis") @val external testAsync: (string, unit => promise<unit>) => unit = "test"
  // Async test with a custom timeout (milliseconds) — for tests with real delays.
  @scope("globalThis") @val
  external testWithTimeout: (string, unit => promise<unit>, int) => unit = "test"
  // Async alias of `testWithTimeout`.
  @scope("globalThis") @val
  external testPromiseWithTimeout: (string, unit => promise<unit>, int) => unit = "test"
  // Skipped async test with a custom timeout.
  @scope(("globalThis", "test")) @val
  external testSkipWithTimeout: (string, unit => promise<unit>, int) => unit = "skip"

  // Pending test placeholder — Jest reports it as "todo" and never runs a body.
  @scope(("globalThis", "test")) @val external todo: string => unit = "todo"

  @scope("globalThis") @val external describe: (string, unit => unit) => unit = "describe"
  @scope("globalThis") @val external beforeEach: (unit => unit) => unit = "beforeEach"
  @scope("globalThis") @val external afterEach: (unit => unit) => unit = "afterEach"
  @scope("globalThis") @val external beforeAll: (unit => unit) => unit = "beforeAll"
  // Async variant — Jest awaits the returned promise before running tests.
  @scope("globalThis") @val external beforeAllAsync: (unit => promise<unit>) => unit = "beforeAll"
  @scope("globalThis") @val external afterAll: (unit => unit) => unit = "afterAll"
  // Async variant — Jest awaits the returned promise after all tests.
  @scope("globalThis") @val external afterAllAsync: (unit => promise<unit>) => unit = "afterAll"

  // Fail the current test with a message. Jest's global `fail` was removed in
  // Jest 27 ESM mode, so this throws a JS Error — the portable way to mark a
  // test failed. Returns 'a so it type-checks in any match/branch position.
  let fail = (message: string): 'a => JsError.throwWithMessage(message)
}

module Expect = {
  @scope("globalThis") @val external expect: 'a => expectResult = "expect"
  @send external toBe: (expectResult, 'a) => unit = "toBe"
  @send external toEqual: (expectResult, 'a) => unit = "toEqual"
  @send external toBeTruthy: expectResult => unit = "toBeTruthy"
  @send external toBeFalsy: expectResult => unit = "toBeFalsy"
  @send external toContain: (expectResult, 'a) => unit = "toContain"
  @send external toHaveLength: (expectResult, int) => unit = "toHaveLength"
  @send external toBeGreaterThan: (expectResult, int) => unit = "toBeGreaterThan"
  @send external toBeGreaterThanOrEqual: (expectResult, int) => unit = "toBeGreaterThanOrEqual"
  @send external toBeCloseTo: (expectResult, float) => unit = "toBeCloseTo"
  @get external not_: expectResult => expectResult = "not"
}

// Flat surface for `open JestGlobals` users (codegen, aws TestHelpers).
include Runner
include Expect
