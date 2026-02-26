// Async-safe Jest bindings for use in reventless-in-memory and dependent packages.
//
// Why not `include ReventlessCore.AsyncTest`: packages that depend on
// reventless-in-memory but not reventless-core can't resolve `@send` external
// bindings that originate in another package's namespace, causing "The value
// toBe can't be found" compile errors. Defining everything locally avoids that.
//
// Workaround for @glennsl/rescript-jest's `testPromise` not returning the async
// Promise to Jest, which causes tests in a describe block to run concurrently
// rather than sequentially.

@val external describe: (string, unit => unit) => unit = "describe"
@val external beforeEach: (unit => unit) => unit = "beforeEach"
@val external afterEach: (unit => unit) => unit = "afterEach"
@val external beforeAll: (unit => unit) => unit = "beforeAll"
@val external beforeAllAsync: (unit => promise<unit>) => unit = "beforeAll"
@val external afterAll: (unit => unit) => unit = "afterAll"

@val external testPromise: (string, unit => promise<unit>) => unit = "test"

type expectResult

module Expect = {
  @val external expect: 'a => expectResult = "expect"
  @send external toBe: (expectResult, 'a) => unit = "toBe"
  @send external toEqual: (expectResult, 'a) => unit = "toEqual"
}
