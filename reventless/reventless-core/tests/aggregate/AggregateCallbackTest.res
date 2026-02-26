open AsyncTest
open AsyncTest.Expect
open AggregateFixtures

let _ = beforeEach(() => mock.reset())

describe("Aggregate_Callback.handleCommands:", () => {
  describe("single command — new aggregate", () => {
    testPromise("Create returns Ok(reference) and stores 1 event", async () => {
      let results = await TestHandler.handleCommands([
        makeTopicItem("ref-1", AggSpec.Create({name: "Widget"})),
      ])
      expect((results, mock.getAll()->Array.length))->toEqual(([Ok("ref-1")], 1))
    })
  })

  describe("command on existing aggregate", () => {
    testPromise("Rename after Create replays history and appends new event", async () => {
      let _ = await TestHandler.handleCommands([
        makeTopicItem("ref-1", AggSpec.Create({name: "Widget"})),
      ])
      let results = await TestHandler.handleCommands([
        makeTopicItem("ref-2", AggSpec.Rename({newName: "Gadget"})),
      ])
      expect((results, mock.getAll()->Array.length))->toEqual(([Ok("ref-2")], 2))
    })
  })

  describe("behavior returns no events", () => {
    testPromise("Rename on new aggregate returns Ok with no event stored", async () => {
      // Rename on empty history: Behavior.create is called; create returns []
      let results = await TestHandler.handleCommands([
        makeTopicItem("ref-1", AggSpec.Rename({newName: "Gadget"})),
      ])
      expect((results, mock.getAll()->Array.length))->toEqual(([Ok("ref-1")], 0))
    })
  })

  describe("append failure", () => {
    testPromise("eventLog.append fails → reference returned Error", async () => {
      mock.failNextAppend := true
      let results = await TestHandler.handleCommands([
        makeTopicItem("ref-1", AggSpec.Create({name: "Widget"})),
      ])
      expect(results)->toEqual([Error("ref-1")])
    })
  })

  describe("multiple commands for same aggregate ID", () => {
    testPromise("Create then Rename in one batch accumulate state correctly", async () => {
      let results = await TestHandler.handleCommands([
        makeTopicItem(~aggId="agg-1", "ref-1", AggSpec.Create({name: "Widget"})),
        makeTopicItem(~aggId="agg-1", "ref-2", AggSpec.Rename({newName: "Gadget"})),
      ])
      // Both commands for same ID processed sequentially
      expect((results, mock.getAll()->Array.length))->toEqual(([Ok("ref-1"), Ok("ref-2")], 2))
    })
  })

  describe("commands for different aggregate IDs", () => {
    testPromise("each ID processed independently", async () => {
      let results = await TestHandler.handleCommands([
        makeTopicItem(~aggId="agg-a", "ref-a", AggSpec.Create({name: "Alpha"})),
        makeTopicItem(~aggId="agg-b", "ref-b", AggSpec.Create({name: "Beta"})),
      ])
      expect((results->Array.length, mock.getAll()->Array.length))->toEqual((2, 2))
    })
  })

  describe("empty batch", () => {
    testPromise("returns empty array", async () => {
      let results = await TestHandler.handleCommands([])
      expect(results)->toEqual([])
    })
  })
})
