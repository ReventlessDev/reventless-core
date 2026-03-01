open AsyncTest
open AsyncTest.Expect
open CommandTopicCallbackFixtures

let _ = beforeEach(() => reset())

describe("CommandTopic_Callback.handleJsonCommands:", () => {
  describe("valid command JSON", () => {
    testPromise("decoded command passed to commandsHandler", async () => {
      let item = makeTopicItem("agg-1", TestSpec.CreateItem({itemId: "item-1"}))
      let _ = await TestHandler.handleJsonCommands(Stream.fromIterable([item]))->Effect.runPromise
      expect(capturedItems.contents->Array.length)->toBe(1)
      let captured = capturedItems.contents->Array.getUnsafe(0)
      expect(captured.reference)->toBe("agg-1")
      expect(captured.command)->toEqual(TestSpec.CreateItem({itemId: "item-1"}))
    })
  })

  describe("results returned from commandsHandler", () => {
    testPromise("handler results propagated as return value", async () => {
      commandHandlerResults := [Ok("agg-1"), Error("agg-2")]
      let item = makeTopicItem("agg-1", TestSpec.CreateItem({itemId: "item-1"}))
      let results = await TestHandler.handleJsonCommands(Stream.fromIterable([item]))->Effect.runPromise
      expect(results)->toEqual([Ok("agg-1"), Error("agg-2")])
    })
  })

  describe("malformed command JSON", () => {
    testPromise("skipped gracefully — commandsHandler called with empty array", async () => {
      let invalidItem: ReventlessCore.CommandTopic.topicItem<JSON.t> = {
        reference: "ref-1",
        command: JSON.Encode.string("not-a-command-object"),
      }
      let _ = await TestHandler.handleJsonCommands(Stream.fromIterable([invalidItem]))->Effect.runPromise
      // Decode fails — commandsHandler called with empty list, returns default [Ok("ref-1")]
      expect(capturedItems.contents->Array.length)->toBe(0)
    })
  })

  describe("multiple commands in batch", () => {
    testPromise("all decodable commands reach commandsHandler", async () => {
      let items = [
        makeTopicItem("agg-1", TestSpec.CreateItem({itemId: "item-1"})),
        makeTopicItem("agg-2", TestSpec.DeleteItem({itemId: "item-2"})),
        makeTopicItem("agg-3", TestSpec.CreateItem({itemId: "item-3"})),
      ]
      let _ = await TestHandler.handleJsonCommands(Stream.fromIterable(items))->Effect.runPromise
      expect(capturedItems.contents->Array.length)->toBe(3)
    })
  })

  describe("mixed valid and invalid commands", () => {
    testPromise("only valid commands reach commandsHandler", async () => {
      let validItem = makeTopicItem("agg-1", TestSpec.CreateItem({itemId: "item-1"}))
      let invalidItem: ReventlessCore.CommandTopic.topicItem<JSON.t> = {
        reference: "ref-bad",
        command: JSON.Encode.null,
      }
      let _ =
        await TestHandler.handleJsonCommands(
          Stream.fromIterable([validItem, invalidItem]),
        )->Effect.runPromise
      expect(capturedItems.contents->Array.length)->toBe(1)
      expect((capturedItems.contents->Array.getUnsafe(0)).reference)->toBe("agg-1")
    })
  })
})
