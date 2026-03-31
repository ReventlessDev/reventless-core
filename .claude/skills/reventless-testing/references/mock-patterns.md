# Mock Patterns

## Factory Functions Over Global State

Use factory functions returning closures over `ref` values — never global mutable refs:

```rescript
let makeMockStorage = () => {
  let events: ref<array<event>> = ref([])
  let failNextAppends: ref<int> = ref(0)

  let append = async (_, _, newEvents) => {
    if failNextAppends.contents > 0 {
      failNextAppends := failNextAppends.contents - 1
      Error("storage error")
    } else {
      events := Array.concat(events.contents, newEvents)
      Ok()
    }
  }

  let replay = async (_id) => events.contents

  let reset = () => {
    events := []
    failNextAppends := 0
  }

  let getState = () => events.contents

  {append, replay, reset, getState, failNextAppends}
}
```

## Counter-Based Failure Injection

Use `failNextWrites: ref<int>` for deterministic retry testing:

```rescript
let mock = makeMockStorage()

jestTest("retries on first failure", async () => {
  mock.failNextAppends := 1  // fail once, then succeed
  let result = await ops.publishJsons([cmd])
  // Command should succeed after retry
  expect(mock.getState()->Array.length)->toBe(1)
})
```

## Test Isolation with Reset

Call `reset()` in `beforeEach`:

```rescript
let mock = makeMockStorage()

beforeEach(() => {
  mock.reset()
})
```

## Inspection Functions

Provide getters for asserting internal state:

```rescript
let getPublishedMessages = () => publishedMessages.contents
let getEventCount = () => events.contents->Array.length
let getLastEvent = () => events.contents->Array.getUnsafe(Array.length(events.contents) - 1)
```

## Stub Unused Builders

When a module type requires a `make` function you don't need in tests:

```rescript
// Never called — satisfies module type only
let make = (...): component => Obj.magic(0)
```
