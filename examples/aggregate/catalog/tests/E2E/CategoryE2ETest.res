// End-to-end test for the Category aggregate using the in-memory platform.

open ReventlessInMemory.AsyncTest
open ReventlessInMemory.AsyncTest.Expect
open Reventless

module Bus = ReventlessInMemory.InMemory_Bus.Make()

// Topic name = Spec.name ++ "Aggr" ++ "EventTopic" = "CategoryAggrEventTopic"
let capturedEventCount: ref<int> = ref(0)
let _ = Bus.subscribeToEvents("CategoryAggrEventTopic", async (_, _, _) => {
  capturedEventCount := capturedEventCount.contents + 1
})

let _ = ReventlessInMemory.TestRunner.setup()

module AggregateMaker = ReventlessInMemory.Aggregate_Builder.Make(Bus)
module CategoryAgg = AggregateMaker.Make(
  Category,
  CategoryBehavior,
  ReventlessInfra.NoEventMappings.Make(Category),
)

let agg = CategoryAgg.make(~api=())

let testMeta: Message.meta = {
  service: "example-test",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}

describe("Category E2E:", () => {
  let _ = beforeEach(() => {
    capturedEventCount := 0
  })

  testPromise("AddCategory command publishes 1 event to the event topic", async () => {
    let ops = await agg->CategoryAgg.operations->ReventlessInMemory.TestRunner.resolve
    let commandJson =
      Category.AddCategory({categoryId: "cat-1", name: "Electronics"})->Message.encode(
        Category.commandSchema,
      )
    await ops.publishJsons([{Message.id: "cat-1", meta: testMeta, commandJson}])
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("RenameCategory on existing category publishes 1 event", async () => {
    let ops = await agg->CategoryAgg.operations->ReventlessInMemory.TestRunner.resolve
    let commandJson =
      Category.RenameCategory({
        categoryId: "cat-1",
        name: "Consumer Electronics",
      })->Message.encode(Category.commandSchema)
    await ops.publishJsons([{Message.id: "cat-1", meta: testMeta, commandJson}])
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise(
    "duplicate AddCategory for same id produces no events (CategoryAlreadyExists error path)",
    async () => {
      let ops = await agg->CategoryAgg.operations->ReventlessInMemory.TestRunner.resolve
      let commandJson =
        Category.AddCategory({categoryId: "cat-1", name: "Duplicate"})->Message.encode(
          Category.commandSchema,
        )
      await ops.publishJsons([{Message.id: "cat-1", meta: testMeta, commandJson}])
      expect(capturedEventCount.contents)->toBe(0)
    },
  )
})
