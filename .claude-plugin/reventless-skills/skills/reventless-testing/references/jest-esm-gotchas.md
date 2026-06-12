# Jest ESM Mode Gotchas

## Async Tests: Use JestGlobals, Not glennsl

`@glennsl/rescript-jest`'s `testPromise` does NOT await the returned Promise — it wraps `callback()` in `() => { affirm(callback()); }`, discarding the Promise so Jest treats the test as synchronous and tests in a describe block race. Its `expect` is also deferred: only an assertion *returned* from the test body actually runs.

**Use `@reventlessdev/rescript-jest` (module `JestGlobals`) instead.** It binds Jest's globals directly with throwing `expect` and native async bodies:

```rescript
open JestGlobals

testSync("sync test", () => expect(1 + 1)->toBe(2))

testPromise("async test", async () => {
  let result = await someAsyncOp()
  expect(result)->toBe(expected)
})
```

`test` registers an async test; `testSync` a synchronous one. Matchers throw on mismatch and return `unit`, so every assertion runs at its line.

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

## Test Bindings (open JestGlobals)

All hand-written tests use the shared bindings from `@reventlessdev/rescript-jest`:

```rescript
open JestGlobals
// describe / test / testSync / testPromise / beforeAll / beforeAllAsync / ...
// matchers (expect, toBe, toEqual, ...) are available flat after this open;
// `module Expect` re-exports them for `open JestGlobals.Expect` if preferred.
```

`expect(...)` matchers throw on mismatch and return `unit`, so every assertion in a body runs at its line — no `->ignore` on intermediate assertions, and no need to return a single assertion from the test.

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
