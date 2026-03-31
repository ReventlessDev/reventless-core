# E2E Test Patterns

## In-Memory Platform E2E Test Structure

```rescript
// 1. Create Bus externally
module Bus = ReventlessInMemory.InMemory_Bus.Make()

// 2. Subscribe to event topics BEFORE wiring
let capturedEventCount: ref<int> = ref(0)
let _ = Bus.subscribeToEvents("ProductAggrEventTopic", async (_, _, _) => {
  capturedEventCount := capturedEventCount.contents + 1
})

// 3. Setup TestRunner
let _ = ReventlessInMemory.TestRunner.setup()

// 4. Build component
module ProductAgg = Platform.Aggregate.Make(Product, ProductBehavior, ...)
let agg = ProductAgg.make(~api=())

// 5. Test
jestTest("Add command publishes event", async () => {
  let ops = await agg->Reventless.Component.operations->ReventlessInMemory.TestRunner.resolve
  await ops.publishJsons([{Message.id: "p1", meta: testMeta, commandJson}])
  expect(capturedEventCount.contents)->toBe(1)
})
```

## DCB E2E: Async Handler Registration

DCB StateChangeSlice handlers register inside `Output.apply` — this is async. You must resolve the Output chain before running tests:

```rescript
describe("CatalogE2E:", () => {
  // Force handler registration to complete
  beforeAllAsync(async () => {
    let _ = await eventLog
      ->Reventless.Component.operations
      ->ReventlessInMemory.TestRunner.resolve
  })

  jestTest("AddProduct command produces event", async () => { ... })
})
```

**`beforeAllAsync`** binding:
```rescript
@val external beforeAllAsync: (unit => promise<unit>) => unit = "beforeAll"
```

## ReadModel E2E: Two Resolves

ReadModel tests need two awaits — one for the outer chain, one for the subscription:

```rescript
beforeAllAsync(async () => {
  // 1. Resolve outer chain (triggers connect)
  let _ = await rm->Reventless.ReadModel.operations->TestRunner.resolve
  // 2. Resolve inner subscription
  let topicResource = pub.resources->Array.getUnsafe(0)
  let _ = await topicResource.name->TestRunner.resolve
})
```

## Topic Name Conventions

| Component | Topic Name Pattern |
|-----------|-------------------|
| Aggregate EventTopic | `{Spec.name} ++ "Aggr" ++ "EventTopic"` |
| DCB EventTopic | `{DcbEventLog name} ++ "EventTopic"` |
| CommandTopic (aggregate) | `{Spec.name} ++ "Aggr" ++ "CmdTopic"` |
| ExtensionPoint CommandTopic | `{Spec.name} ++ "ExtPoint" ++ "CmdTopic"` |

## Accessing Component Operations

```rescript
// CORRECT — use Component.operations
let ops = await component
  ->ReventlessCore.Component.operations
  ->ReventlessInMemory.TestRunner.resolve

// WRONG — Maker modules don't have operations
let ops = SomeMaker.operations  // does NOT work
```
