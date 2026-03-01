// AsyncTest.res — Jest bindings for rescript-effect tests.
// Binds directly to Jest globals via @val external (no npm package import needed).
// testPromise is the correct async test binding — rescript-jest's testPromise discards
// the returned Promise. See reventless-core/tests/AsyncTest.res for details.

@val external describe: (string, unit => unit) => unit = "describe"
// Async test — callback returns a Promise; Jest awaits it before starting the next test
@val external testPromise: (string, unit => promise<unit>) => unit = "test"
// Sync test — callback returns unit
@val external test: (string, unit => unit) => unit = "test"

@val external beforeAll: (unit => unit) => unit = "beforeAll"
@val external beforeAllAsync: (unit => promise<unit>) => unit = "beforeAll"
@val external beforeEach: (unit => unit) => unit = "beforeEach"
@val external afterAll: (unit => unit) => unit = "afterAll"

type expectResult

// Convert an Effect Chunk to a plain ReScript array.
// Needed because Effect functions like Queue.takeAll and Cause.failures return
// Chunk<A> (a persistent data structure), not a plain JS array. Jest's toEqual
// compares Chunk objects by shape, not by iterable contents — use arrayFrom first.
@val external arrayFrom: 'chunk => array<'a> = "Array.from"

module Expect = {
  @val external expect: 'a => expectResult = "expect"
  @send external toBe: (expectResult, 'a) => unit = "toBe"
  @send external toEqual: (expectResult, 'a) => unit = "toEqual"
  @send external toBeTruthy: expectResult => unit = "toBeTruthy"
  @send external toBeFalsy: expectResult => unit = "toBeFalsy"
  @send external toHaveLength: (expectResult, int) => unit = "toHaveLength"
  @send external toContain: (expectResult, 'a) => unit = "toContain"
  @send external toBeGreaterThan: (expectResult, int) => unit = "toBeGreaterThan"
}
