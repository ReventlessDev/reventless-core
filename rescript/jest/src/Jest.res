// glennsl's `Jest` names and types over Jest's globals. Where glennsl builds
// an assertion that only runs when it is returned, every matcher here runs at
// once and throws on failure; `testPromise` hands its promise to Jest. All
// globals go through `@scope("globalThis")`, so a local `let test` in a
// consumer cannot capture them.

type assertion = unit

module type Registrar = {
  let test: (string, unit => assertion) => unit
  let testDone: (string, (unit => unit) => unit, option<int>) => unit
  let testPromise: (string, unit => promise<assertion>, option<int>) => unit
  let describe: (string, unit => unit) => unit
}

module MakeRunner = (R: Registrar) => {
  let test = R.test
  let testAsync = (name, ~timeout=?, callback) =>
    R.testDone(name, finish => callback(_ => finish()), timeout)
  let testPromise = (name, ~timeout=?, callback) => R.testPromise(name, callback, timeout)
  let testAll = (name, inputs, callback) =>
    inputs->List.forEach(input => R.test(`${name} - ${input->String.make}`, () => callback(input)))
  let testAllPromise = (name, inputs, ~timeout=?, callback) =>
    inputs->List.forEach(input =>
      R.testPromise(`${name} - ${input->String.make}`, () => callback(input), timeout)
    )
  let describe = R.describe
}

module Global = {
  @scope("globalThis") @val external test: (string, unit => assertion) => unit = "test"
  @scope("globalThis") @val
  external testDone: (string, (unit => unit) => unit, option<int>) => unit = "test"
  @scope("globalThis") @val
  external testPromise: (string, unit => promise<assertion>, option<int>) => unit = "test"
  @scope("globalThis") @val external describe: (string, unit => unit) => unit = "describe"
}

module OnlyRegistrar = {
  @scope(("globalThis", "test")) @val external test: (string, unit => assertion) => unit = "only"
  @scope(("globalThis", "test")) @val
  external testDone: (string, (unit => unit) => unit, option<int>) => unit = "only"
  @scope(("globalThis", "test")) @val
  external testPromise: (string, unit => promise<assertion>, option<int>) => unit = "only"
  @scope(("globalThis", "describe")) @val
  external describe: (string, unit => unit) => unit = "only"
}

module SkipRegistrar = {
  @scope(("globalThis", "test")) @val external test: (string, unit => assertion) => unit = "skip"
  @scope(("globalThis", "test")) @val
  external testDone: (string, (unit => unit) => unit, option<int>) => unit = "skip"
  @scope(("globalThis", "test")) @val
  external testPromise: (string, unit => promise<assertion>, option<int>) => unit = "skip"
  @scope(("globalThis", "describe")) @val
  external describe: (string, unit => unit) => unit = "skip"
}

include MakeRunner(Global)
module Only = MakeRunner(OnlyRegistrar)
module Skip = MakeRunner(SkipRegistrar)

module Todo = {
  @scope(("globalThis", "test")) @val external test: string => unit = "todo"
}

module Hooks = {
  @scope("globalThis") @val external beforeAll: (unit => unit) => unit = "beforeAll"
  @scope("globalThis") @val
  external beforeAllDone: ((unit => unit) => unit, option<int>) => unit = "beforeAll"
  @scope("globalThis") @val
  external beforeAllPromise: (unit => promise<'a>, option<int>) => unit = "beforeAll"
  @scope("globalThis") @val external beforeEach: (unit => unit) => unit = "beforeEach"
  @scope("globalThis") @val
  external beforeEachDone: ((unit => unit) => unit, option<int>) => unit = "beforeEach"
  @scope("globalThis") @val
  external beforeEachPromise: (unit => promise<'a>, option<int>) => unit = "beforeEach"
  @scope("globalThis") @val external afterAll: (unit => unit) => unit = "afterAll"
  @scope("globalThis") @val
  external afterAllDone: ((unit => unit) => unit, option<int>) => unit = "afterAll"
  @scope("globalThis") @val
  external afterAllPromise: (unit => promise<'a>, option<int>) => unit = "afterAll"
  @scope("globalThis") @val external afterEach: (unit => unit) => unit = "afterEach"
  @scope("globalThis") @val
  external afterEachDone: ((unit => unit) => unit, option<int>) => unit = "afterEach"
  @scope("globalThis") @val
  external afterEachPromise: (unit => promise<'a>, option<int>) => unit = "afterEach"
}

// Jest treats an argument passed to `done` as a failure, so it is called bare.
let withDone = (callback, finish) => callback(() => finish())

let beforeAll = Hooks.beforeAll
let beforeAllAsync = (~timeout=?, callback) => Hooks.beforeAllDone(withDone(callback, ...), timeout)
let beforeAllPromise = (~timeout=?, callback) => Hooks.beforeAllPromise(callback, timeout)
let beforeEach = Hooks.beforeEach
let beforeEachAsync = (~timeout=?, callback) =>
  Hooks.beforeEachDone(withDone(callback, ...), timeout)
let beforeEachPromise = (~timeout=?, callback) => Hooks.beforeEachPromise(callback, timeout)
let afterAll = Hooks.afterAll
let afterAllAsync = (~timeout=?, callback) => Hooks.afterAllDone(withDone(callback, ...), timeout)
let afterAllPromise = (~timeout=?, callback) => Hooks.afterAllPromise(callback, timeout)
let afterEach = Hooks.afterEach
let afterEachAsync = (~timeout=?, callback) => Hooks.afterEachDone(withDone(callback, ...), timeout)
let afterEachPromise = (~timeout=?, callback) => Hooks.afterEachPromise(callback, timeout)

let pass = ()
let fail = message => JsError.throwWithMessage(message)

module Expect = {
  type plainPartial<'a> = [#Just('a)]
  type invertedPartial<'a> = [#Not('a)]
  type partial<'a> = [
    | plainPartial<'a>
    | invertedPartial<'a>
  ]

  type matchers
  type asymmetricMatcher

  module Js = {
    @scope("globalThis") @val external expect: 'a => matchers = "expect"
    @scope(("globalThis", "expect")) @val
    external arrayContaining: array<'a> => asymmetricMatcher = "arrayContaining"
    @get external not: matchers => matchers = "not"
    @send external toBe: (matchers, 'a) => unit = "toBe"
    @send external toBeCloseTo: (matchers, float) => unit = "toBeCloseTo"
    @send external toBeCloseToDigits: (matchers, float, int) => unit = "toBeCloseTo"
    @send external toBeGreaterThan: (matchers, 'a) => unit = "toBeGreaterThan"
    @send external toBeGreaterThanOrEqual: (matchers, 'a) => unit = "toBeGreaterThanOrEqual"
    @send external toBeLessThan: (matchers, 'a) => unit = "toBeLessThan"
    @send external toBeLessThanOrEqual: (matchers, 'a) => unit = "toBeLessThanOrEqual"
    @send external toContain: (matchers, 'a) => unit = "toContain"
    @send external toContainEqual: (matchers, 'a) => unit = "toContainEqual"
    @send external toEqual: (matchers, 'a) => unit = "toEqual"
    @send external toEqualMatcher: (matchers, asymmetricMatcher) => unit = "toEqual"
    @send external toHaveLength: (matchers, int) => unit = "toHaveLength"
    @send external toMatch: (matchers, RegExp.t) => unit = "toMatch"
    @send external toThrow: matchers => unit = "toThrow"
  }

  let matchers = (partial: [< partial<'a>]) =>
    switch partial {
    | #Just(a) => Js.expect(a)
    | #Not(a) => Js.expect(a)->Js.not
    }

  let expect = a => #Just(a)
  let expectFn = (f, a) => #Just(() => f(a))

  let toBe = (p, b) => matchers(p)->Js.toBe(b)
  let toBeCloseTo = (p, b) => matchers(p)->Js.toBeCloseTo(b)
  let toBeSoCloseTo = (p, ~digits, b) => matchers(p)->Js.toBeCloseToDigits(b, digits)
  let toBeGreaterThan = (p, b) => matchers(p)->Js.toBeGreaterThan(b)
  let toBeGreaterThanOrEqual = (p, b) => matchers(p)->Js.toBeGreaterThanOrEqual(b)
  let toBeLessThan = (p, b) => matchers(p)->Js.toBeLessThan(b)
  let toBeLessThanOrEqual = (p, b) => matchers(p)->Js.toBeLessThanOrEqual(b)
  let toBeSupersetOf = (p, b) => matchers(p)->Js.toEqualMatcher(Js.arrayContaining(b))
  let toContain = (p, b) => matchers(p)->Js.toContain(b)
  let toContainEqual = (p, b) => matchers(p)->Js.toContainEqual(b)
  // Jest's `toContain` on a string is a substring test.
  let toContainString = (p, b) => matchers(p)->Js.toContain(b)
  let toEqual = (p, b) => matchers(p)->Js.toEqual(b)
  let toHaveLength = (p, length) => matchers(p)->Js.toHaveLength(length)
  // As in glennsl, the string is a regular expression.
  let toMatch = (p, s) => matchers(p)->Js.toMatch(RegExp.fromString(s))
  let toMatchRe = (p, re) => matchers(p)->Js.toMatch(re)
  let toThrow = p => matchers(p)->Js.toThrow

  let not_ = (#Just(a)) => #Not(a)
  let not__ = not_

  module Operators = {
    let \"==" = toEqual
    let \"===" = toBe
    let \"!=" = (a, b) => a->not_->toEqual(b)
    let \"!==" = (a, b) => a->not_->toBe(b)
    let \">" = toBeGreaterThan
    let \">=" = toBeGreaterThanOrEqual
    let \"<" = toBeLessThan
    let \"<=" = toBeLessThanOrEqual
  }
}

module Jest = {
  type fakeTimerImplementation = [#legacy | #modern]
  type fakeTimersConfig = {legacyFakeTimers: bool}
  @module("@jest/globals") @scope("jest")
  external advanceTimersByTime: int => unit = "advanceTimersByTime"
  @module("@jest/globals") @scope("jest") external runAllTimers: unit => unit = "runAllTimers"
  @module("@jest/globals") @scope("jest")
  external runOnlyPendingTimers: unit => unit = "runOnlyPendingTimers"
  @module("@jest/globals") @scope("jest")
  external useFakeTimersWith: fakeTimersConfig => unit = "useFakeTimers"
  @module("@jest/globals") @scope("jest") external useRealTimers: unit => unit = "useRealTimers"
  @module("@jest/globals") @scope("jest")
  external setSystemTimeWithInt: int => unit = "setSystemTime"
  @module("@jest/globals") @scope("jest")
  external setSystemTimeWithDate: Date.t => unit = "setSystemTime"

  // Jest 27 took the implementation as a string; 29 and 30 take a config.
  let useFakeTimers = (~implementation=#modern, ()) =>
    useFakeTimersWith({legacyFakeTimers: implementation == #legacy})

  type systemTime = [#int(int) | #date(Date.t)]
  let setSystemTime = systemTime =>
    switch systemTime {
    | #int(ms) => setSystemTimeWithInt(ms)
    | #date(date) => setSystemTimeWithDate(date)
    }
}
