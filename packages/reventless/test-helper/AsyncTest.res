// Workaround for @glennsl/rescript-jest's `testPromise` not returning the async
// Promise to Jest, which causes tests in a describe block to run concurrently
// rather than sequentially.
//
// Root cause: the internal `test` wrapper in rescript-jest wraps the callback in
// `() => { affirm(callback()); }`, discarding the returned Promise so Jest treats
// the test as synchronous.
//
// This module binds directly to Jest's global `test` and `expect`, which properly
// await async functions.
//
// See docs/fixes/rescript-jest-testpromise-async.md for a full explanation and
// docs/fixes/rescript-jest-testpromise-issue.md for the upstream issue report.

// Standard Jest lifecycle globals — bound directly so tests using this module
// do not need to `open Jest` (which would cause a warning-44 shadow on testPromise).
@val external describe: (string, unit => unit) => unit = "describe"
@val external beforeEach: (unit => unit) => unit = "beforeEach"
@val external afterEach: (unit => unit) => unit = "afterEach"
@val external beforeAll: (unit => unit) => unit = "beforeAll"
// Async variant of beforeAll — Jest awaits the returned promise before running tests.
@val external beforeAllAsync: (unit => promise<unit>) => unit = "beforeAll"
@val external afterAll: (unit => unit) => unit = "afterAll"

// Registers an async test that Jest properly awaits before running the next test.
@val external testPromise: (string, unit => promise<unit>) => unit = "test"

// Opaque handle returned by `expect`.
type expectResult

module Expect = {
  @val external expect: 'a => expectResult = "expect"
  @send external toBe: (expectResult, 'a) => unit = "toBe"
  @send external toEqual: (expectResult, 'a) => unit = "toEqual"
}
