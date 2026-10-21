// glennsl's `Jest` surface with this package's behavior: every matcher runs
// where it is written, and an async test is awaited. A suite on
// `@glennsl/rescript-jest` compiles against it unchanged.

type assertion

let test: (string, unit => assertion) => unit
let testAsync: (string, ~timeout: int=?, (assertion => unit) => unit) => unit
let testPromise: (string, ~timeout: int=?, unit => promise<assertion>) => unit
let testAll: (string, list<'a>, 'a => assertion) => unit
let testAllPromise: (string, list<'a>, ~timeout: int=?, 'a => promise<assertion>) => unit

let describe: (string, unit => unit) => unit

let beforeAll: (unit => unit) => unit
let beforeAllAsync: (~timeout: int=?, (unit => unit) => unit) => unit
let beforeAllPromise: (~timeout: int=?, unit => promise<'a>) => unit
let beforeEach: (unit => unit) => unit
let beforeEachAsync: (~timeout: int=?, (unit => unit) => unit) => unit
let beforeEachPromise: (~timeout: int=?, unit => promise<'a>) => unit
let afterAll: (unit => unit) => unit
let afterAllAsync: (~timeout: int=?, (unit => unit) => unit) => unit
let afterAllPromise: (~timeout: int=?, unit => promise<'a>) => unit
let afterEach: (unit => unit) => unit
let afterEachAsync: (~timeout: int=?, (unit => unit) => unit) => unit
let afterEachPromise: (~timeout: int=?, unit => promise<'a>) => unit

module Only: {
  let test: (string, unit => assertion) => unit
  let testAsync: (string, ~timeout: int=?, (assertion => unit) => unit) => unit
  let testPromise: (string, ~timeout: int=?, unit => promise<assertion>) => unit
  let testAll: (string, list<'a>, 'a => assertion) => unit
  let testAllPromise: (string, list<'a>, ~timeout: int=?, 'a => promise<assertion>) => unit
  let describe: (string, unit => unit) => unit
}

module Skip: {
  let test: (string, unit => assertion) => unit
  let testAsync: (string, ~timeout: int=?, (assertion => unit) => unit) => unit
  let testPromise: (string, ~timeout: int=?, unit => promise<assertion>) => unit
  let testAll: (string, list<'a>, 'a => assertion) => unit
  let testAllPromise: (string, list<'a>, ~timeout: int=?, 'a => promise<assertion>) => unit
  let describe: (string, unit => unit) => unit
}

module Todo: {
  let test: string => unit
}

// Checks nothing, as in glennsl.
let pass: assertion
// Throws at once, failing the test with `message`.
let fail: string => assertion

module Expect: {
  type plainPartial<'a> = [#Just('a)]
  type invertedPartial<'a> = [#Not('a)]
  type partial<'a> = [
    | plainPartial<'a>
    | invertedPartial<'a>
  ]

  let expect: 'a => plainPartial<'a>
  let expectFn: ('a => 'b, 'a) => plainPartial<unit => 'b>

  let toBe: ([< partial<'a>], 'a) => assertion
  let toBeCloseTo: ([< partial<float>], float) => assertion
  let toBeSoCloseTo: ([< partial<float>], ~digits: int, float) => assertion
  let toBeGreaterThan: ([< partial<'a>], 'a) => assertion
  let toBeGreaterThanOrEqual: ([< partial<'a>], 'a) => assertion
  let toBeLessThan: ([< partial<'a>], 'a) => assertion
  let toBeLessThanOrEqual: ([< partial<'a>], 'a) => assertion
  let toBeSupersetOf: ([< partial<array<'a>>], array<'a>) => assertion
  let toContain: ([< partial<array<'a>>], 'a) => assertion
  let toContainEqual: ([< partial<array<'a>>], 'a) => assertion
  let toContainString: ([< partial<string>], string) => assertion
  let toEqual: ([< partial<'a>], 'a) => assertion
  let toHaveLength: ([< partial<array<'a>>], int) => assertion
  let toMatch: ([< partial<string>], string) => assertion
  let toMatchRe: ([< partial<string>], RegExp.t) => assertion
  let toThrow: [< partial<unit => _>] => assertion

  let not_: plainPartial<'a> => invertedPartial<'a>
  let not__: plainPartial<'a> => invertedPartial<'a>

  module Operators: {
    let \"==": ([< partial<'a>], 'a) => assertion
    let \"===": ([< partial<'a>], 'a) => assertion
    let \"!=": (plainPartial<'a>, 'a) => assertion
    let \"!==": (plainPartial<'a>, 'a) => assertion
    let \">": ([< partial<'a>], 'a) => assertion
    let \">=": ([< partial<'a>], 'a) => assertion
    let \"<": ([< partial<'a>], 'a) => assertion
    let \"<=": ([< partial<'a>], 'a) => assertion
  }
}

// Jest's fake timers, read off `@jest/globals`: the `jest` object is no
// global under ESM, and under CommonJS only a parameter of each test module.
module Jest: {
  type fakeTimerImplementation = [#legacy | #modern]
  let advanceTimersByTime: int => unit
  let runAllTimers: unit => unit
  let runOnlyPendingTimers: unit => unit
  let useFakeTimers: (~implementation: fakeTimerImplementation=?, unit) => unit
  let useRealTimers: unit => unit
  type systemTime = [#int(int) | #date(Date.t)]
  let setSystemTime: systemTime => unit
}
