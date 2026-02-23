# Fix: `testPromise` in `@glennsl/rescript-jest` does not await async tests

## Context

Discovered while implementing `packages/reventless-example-aggregate/` E2E tests.
The E2E tests use the in-memory platform to verify the full command → event pipeline.

## Symptom

Three `testPromise` tests in a `describe` block sharing a module-level `capturedEventCount` ref:

```rescript
describe("CatalogItem E2E:", () => {
  let _ = beforeEach(() => { capturedEventCount := 0 })

  testPromise("CreateItem command publishes 1 event", async () => {
    await ops.publishJsons([CreateItem(...)])
    expect(capturedEventCount.contents)->toBe(1)   // ← fails: Received 2
  })

  testPromise("UpdateItem publishes 1 event", async () => {
    await ops.publishJsons([UpdateItem(...)])
    expect(capturedEventCount.contents)->toBe(1)
  })
  ...
})
```

Test 1 fails with:
```
JestAssertionError: Expected: 1, Received: 2
```

Logs showed test 2's command handler firing *before* test 1's `publishJsons` resolved:
```
Handling command 1/1: CreateItem(item-1)
Published event 1/1: ItemCreated(item-1)     ← count = 1
Handling command 1/1: UpdateItem(item-1)     ← test 2 already running!
Published event 1/1: ItemUpdated(item-1)     ← count = 2
Published commands 1/1: CreateItem(item-1)   ← test 1's publishJsons finally resolves
Published commands 1/1: UpdateItem(item-1)
```

## Root Cause

`testPromise` in `@glennsl/rescript-jest` wraps the async callback in a synchronous
wrapper that **discards the returned Promise**:

```js
// jest.res.mjs

function test(name, callback) {
  globalThis.test(name, () => {
    affirm(callback());   // ← returns undefined, NOT the Promise
  });
}

function testPromise(name, timeout, callback) {
  test(name, () => callback().then(a => Promise.resolve(affirm(a))), timeout);
  //          ↑ this inner fn calls callback() but the outer wrapper above
  //            calls affirm(innerFn()) and returns undefined
}
```

`callback()` — the inner lambda `() => asyncFn().then(...)` — *does* return a Promise,
but `affirm(promise)` does nothing with it (no matching `TAG` in the switch), so the
outer wrapper returns `undefined`. Jest receives `undefined`, treats the test as
synchronous, and immediately schedules the next test.

All `testPromise` tests in a describe block therefore start their async chains
**concurrently**. Shared mutable state (e.g. a module-level event counter) races between
the concurrent chains.

### Why `AggregateE2ETest` accidentally passes

The reference test in `reventless-in-memory` uses the same broken `testPromise`, but its
test 2 is a *duplicate* CreateItem that produces **0 events** (AlreadyExists error path).
The race condition exists there too, but is invisible: even if all three chains overlap,
the zero-event test 2 does not increment the counter, so test 1's assertion happens to see
the right value. The moment any test 2 produces an event (as UpdateItem does in
CatalogItemE2ETest), the race surfaces.

## Fix

Bypass `testPromise` and bind directly to Jest's global `test`, which properly awaits
async functions when they return a Promise.

### ReScript bindings

```rescript
type expectResult
@val external jestTest: (string, unit => promise<unit>) => unit = "test"
@val external nativeExpect: 'a => expectResult = "expect"
@send external nativeToBe: (expectResult, 'a) => unit = "toBe"
```

### Usage

```rescript
jestTest("CreateItem command publishes 1 event", async () => {
  let ops = await agg->ItemAgg.operations->ReventlessInMemory.TestRunner.resolve
  await ops.publishJsons([...])
  nativeExpect(capturedEventCount.contents)->nativeToBe(1)
  // nativeExpect(...).toBe(...) throws JestAssertionError on failure,
  // which Jest catches correctly inside a properly-awaited async test
})
```

`nativeExpect` maps to Jest's global `expect`. When the assertion fails it throws
`JestAssertionError`; the async function rejects; Jest (now properly awaiting the
Promise) catches the rejection and marks the test as failed.

`beforeEach` (the global, not rescript-jest's `beforeEachAsync`) continues to work
correctly — Jest awaits each async test before running the next `beforeEach`.

## Files changed

- `packages/reventless-example-aggregate/tests/Aggregate/CatalogItemE2ETest.res`
  — replaced `testPromise` + `expect->toBe` with `jestTest` + `nativeExpect->nativeToBe`
