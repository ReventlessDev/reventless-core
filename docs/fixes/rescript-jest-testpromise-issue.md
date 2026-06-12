# Issue report: `testPromise` silently drops the async Promise, causing concurrent test execution

> **Superseded (2026-06-12).** This repo no longer depends on
> `@glennsl/rescript-jest`; hand-written tests use `@reventlessdev/rescript-jest`
> (`JestGlobals`). Retained as the historical upstream-issue write-up.

**Project**: `@glennsl/rescript-jest`
**Repo**: https://github.com/glennsl/rescript-jest

---

## Summary

`testPromise` registers an async test with Jest but does not return the Promise to Jest's
test runner. Jest therefore treats each `testPromise` test as synchronous and immediately
starts the next test, causing all tests in a `describe` block to run **concurrently**
rather than sequentially. Shared mutable state races between the concurrent async chains
and produces non-deterministic failures.

## Steps to reproduce

```rescript
open Jest
open Expect

let count: ref<int> = ref(0)

describe("async counter", () => {
  let _ = beforeEach(() => { count := 0 })

  testPromise("test 1 increments count once", async () => {
    // Simulate async work that fires an event
    await Promise.resolve()
    count := count.contents + 1
    expect(count.contents)->toBe(1)   // ← may see 2
  })

  testPromise("test 2 also increments count", async () => {
    await Promise.resolve()
    count := count.contents + 1
    expect(count.contents)->toBe(1)
  })
})
```

**Expected**: tests run sequentially; each assertion sees `count = 1`.

**Actual**: both async chains start concurrently; by the time test 1's assertion runs,
test 2 may have already incremented `count` to 2, causing a spurious failure.

## Root cause

`testPromise` delegates to the module-local `test` helper:

```js
// jest.res.mjs

function test(name, callback) {
  globalThis.test(name, () => {
    affirm(callback());   // ← outer fn returns undefined, not the Promise
  });
}

function testPromise(name, timeout, callback) {
  // callback = () => asyncFn().then(a => Promise.resolve(affirm(a)))
  test(name, () => callback().then(a => Promise.resolve(affirm(a))), timeout);
}
```

The chain of calls is:

1. `testPromise` constructs an inner lambda `innerFn = () => asyncFn().then(...)`.
2. `testPromise` calls the local `test(name, innerFn, timeout)`.
3. The local `test` calls `globalThis.test(name, () => { affirm(innerFn()); })`.
4. Inside that wrapper, `innerFn()` *does* return a Promise — but `affirm(promise)`
   does nothing (a Promise has no `.TAG` property, so the switch falls through and
   returns `undefined`).
5. The wrapper passed to `globalThis.test` therefore returns `undefined`.
6. Jest sees `undefined`, treats the test as synchronous, and **does not await the
   async chain**.

The `timeout` argument is also silently dropped because the local `test` function only
accepts two parameters.

## Expected behaviour

The function registered with `globalThis.test` should return the Promise so that Jest
awaits it and runs tests sequentially.

## Proposed fix

The fix is a one-liner in `jest.res`: call `globalThis.test` directly instead of routing
through the local `test` wrapper.

**ReScript source (`jest.res`)**:
```rescript
// Before
let testPromise = (name, ~timeout=?, callback) =>
  test(name, () => callback()->Promise.then(a => Promise.resolve(affirm(a))), ~timeout?)

// After — call the JS global directly so the Promise is returned to Jest
@val external globalTest: (string, unit => promise<'a>, ~timeout: int=?) => unit = "test"

let testPromise = (name, ~timeout=?, callback) =>
  globalTest(name, () => callback()->Promise.then(a => Promise.resolve(affirm(a))), ~timeout?)
```

**Resulting JS**:
```js
// Before
function testPromise(name, timeout, callback) {
  test(name, () => callback().then(a => Promise.resolve(affirm(a))), timeout);
  // ↑ local `test` wraps callback in () => { affirm(cb()); } — Promise dropped
}

// After
function testPromise(name, timeout, callback) {
  globalThis.test(name, () => callback().then(a => Promise.resolve(affirm(a))), timeout);
  // ↑ inner lambda returns the Promise directly — Jest awaits it
}
```

The same one-line change applies to `testPromise` in the `Only` and `Runner` variants.
The `timeout` parameter is also now forwarded correctly (the local `test` wrapper only
accepted two arguments, silently dropping it).

## Workaround

Until the library is fixed, bypass `testPromise` with direct bindings to Jest's globals:

```rescript
type expectResult
@val external jestTest: (string, unit => promise<unit>) => unit = "test"
@val external nativeExpect: 'a => expectResult = "expect"
@send external nativeToBe: (expectResult, 'a) => unit = "toBe"

jestTest("my async test", async () => {
  await doSomethingAsync()
  nativeExpect(result)->nativeToBe(expected)
})
```

`nativeExpect(...).toBe(...)` calls Jest's built-in `expect`, which throws
`JestAssertionError` on failure. Jest properly catches it because the async function is
now correctly awaited.

## Environment

- `@glennsl/rescript-jest` 0.13.1
- Jest 29 / Node 22 / ReScript 12
- `NODE_OPTIONS=--experimental-vm-modules` (ESM test runner)

## Notes

The bug is subtle because it is **sometimes invisible**: if all `testPromise` tests in a
suite produce only passing assertions by coincidence of microtask ordering (e.g. when one
test expects `count = 0` because it triggers no events), the concurrency goes unnoticed.
It only surfaces when two concurrent async chains both produce side effects that are
checked by independent assertions.
