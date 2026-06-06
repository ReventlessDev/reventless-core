# Jest ESM Mode Gotchas

## testPromise Is Broken

`@glennsl/rescript-jest`'s `testPromise` does NOT await the returned Promise. It wraps `callback()` in `() => { affirm(callback()); }` which discards the Promise, making Jest treat the test as synchronous. All `testPromise` tests in a describe block run concurrently.

**Fix:** Use native Jest binding:

```rescript
type expectResult
@val external jestTest: (string, unit => promise<unit>) => unit = "test"
@val external nativeExpect: 'a => expectResult = "expect"
@send external nativeToBe: (expectResult, 'a) => unit = "toBe"
@send external nativeToEqual: (expectResult, 'a) => unit = "toEqual"

jestTest("my async test", async () => {
  let result = await someAsyncOp()
  nativeExpect(result)->nativeToBe(expected)
})
```

## jest Object in ESM Mode

The `jest` object is NOT injected as a bare global in ESM mode. Import it:

```rescript
type jestObj
@module("@jest/globals") external jest: jestObj = "jest"
@send external useFakeTimers: jestObj => unit = "useFakeTimers"
@send external useRealTimers: jestObj => unit = "useRealTimers"
@send external advanceTimersByTime: (jestObj, int) => unit = "advanceTimersByTime"
```

Place `useFakeTimers` in `beforeAll`, not at module top level:

```rescript
beforeAll(() => {
  jest->useFakeTimers
})
```

## beforeAllAsync

For async setup (resolving Output chains before tests):

```rescript
@val external beforeAllAsync: (unit => promise<unit>) => unit = "beforeAll"

beforeAllAsync(async () => {
  let _ = await component->Component.operations->TestRunner.resolve
})
```

## Array.getUnsafe Chaining

ReScript parses `arr->Array.getUnsafe(0).field` incorrectly:

```rescript
// WRONG
let name = items->Array.getUnsafe(0).name

// CORRECT
let first = items->Array.getUnsafe(0)
let name = first.name
```

## AsyncTest Open Pattern

For in-memory adapter tests:

```rescript
open AsyncTest
open AsyncTest.Expect
// Do NOT open Jest alongside AsyncTest
```

All tests use `testPromise`. `expect` from `AsyncTest.Expect` returns `unit` (not `Jest.assertion`), so no `->ignore` is needed on intermediate assertions.

## Fake Timer Test Isolation

Reset timers/intervals at the end of each test:

```rescript
afterEach(() => {
  SP.reset()
  // or LocalHeartbeatRunner.reset()
})
```

## NODE_OPTIONS for ESM

Jest config in `package.json` must run with ESM support:

```json
{
  "scripts": {
    "test": "NODE_OPTIONS='--experimental-vm-modules' npx jest"
  }
}
```

## Module Name Mapper

Required Jest config to prevent native dependency failures:

```json
{
  "jest": {
    "moduleNameMapper": {
      "^@npmcli/arborist$": "<rootDir>/__mocks__/emptyModule.js",
      "^spdx-license-ids$": "<rootDir>/../../../node_modules/spdx-license-ids/index.json",
      "^spdx-license-ids/deprecated$": "<rootDir>/../../../node_modules/spdx-license-ids/deprecated.json",
      "^spdx-exceptions$": "<rootDir>/../../../node_modules/spdx-exceptions/index.json"
    }
  }
}
```
