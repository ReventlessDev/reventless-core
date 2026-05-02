// Unit tests for AutomationSlice_Callback (Plan 04 mixed-source shape) —
// exercises per-source decode dispatch, context plumbing, and toTags
// validation.

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect
open AutomationSliceFixtures

module Callback = ReventlessCore.AutomationSlice_Callback.Make(
  ShipOrderSpec,
  ShipOrderAutomation,
)

module SkipCallback = ReventlessCore.AutomationSlice_Callback.Make(
  SkipProcessSpec,
  SkipProcessAutomation,
)

open ReventlessCore.AutomationSlice_Callback

describe("AutomationSlice Callback (mixed-source)", () => {
  let _ = beforeEach(() => {
    Callback.todoItems
    ->Dict.keysToArray
    ->Array.forEach(k => Callback.todoItems->Dict.delete(k))
    SkipCallback.todoItems
    ->Dict.keysToArray
    ->Array.forEach(k => SkipCallback.todoItems->Dict.delete(k))
  })

  describe("Phase 1 — collect", () => {
    testPromise("OrderPlaced JSON creates a pending TODO item", async () => {
      let json = encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "123 Main St"}))
      Callback.phase1([json], testContext)
      let items = Callback.todoItems
      expect(items->Dict.toArray->Array.length)->toBe(1)
      let row = items->Dict.get("ord-1")->Option.getOrThrow
      expect(row.status)->toBe(Pending)
      expect(row.retryCount)->toBe(0)
    })

    testPromise("duplicate OrderPlaced is idempotent", async () => {
      let j1 = encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "123 Main St"}))
      let j2 = encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "456 Oak Ave"}))
      Callback.phase1([j1], testContext)
      Callback.phase1([j2], testContext)
      expect(Callback.todoItems->Dict.toArray->Array.length)->toBe(1)
    })

    testPromise("multiple OrderPlaced events create multiple TODO items", async () => {
      let j1 = encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "123 Main St"}))
      let j2 = encodeShipOrderEvent(OrderPlaced({orderId: "ord-2", address: "456 Oak Ave"}))
      Callback.phase1([j1, j2], testContext)
      expect(Callback.todoItems->Dict.toArray->Array.length)->toBe(2)
    })

    testPromise("ShipmentCreated does not create a TODO item", async () => {
      let json = encodeShipOrderEvent(ShipmentCreated({orderId: "ord-1"}))
      Callback.phase1([json], testContext)
      expect(Callback.todoItems->Dict.toArray->Array.length)->toBe(0)
    })
  })

  describe("Phase 1 — resolve", () => {
    testPromise("ShipmentCreated marks pending TODO item as completed", async () => {
      Callback.phase1(
        [encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "123 Main St"}))],
        testContext,
      )
      Callback.phase1(
        [encodeShipOrderEvent(ShipmentCreated({orderId: "ord-1"}))],
        testContext,
      )
      let row = Callback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row.status)->toBe(Completed)
    })

    testPromise("ShipmentCreated for unknown id is a no-op", async () => {
      Callback.phase1(
        [encodeShipOrderEvent(ShipmentCreated({orderId: "unknown"}))],
        testContext,
      )
      expect(Callback.todoItems->Dict.toArray->Array.length)->toBe(0)
    })
  })

  describe("Phase 2 — process", () => {
    testPromise("pending items produce commands via publishJsons", async () => {
      Callback.phase1(
        [encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "123 Main St"}))],
        testContext,
      )
      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }
      await Callback.phase2(mockPublish)

      expect(publishedCommands.contents->Array.length)->toBe(1)
      let cmd = publishedCommands.contents->Array.getUnsafe(0)
      expect(cmd.id)->toBe("ord-1")

      let row = Callback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row.status)->toBe(Processing)
    })

    testPromise("completed items are not processed", async () => {
      Callback.phase1(
        [encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "123 Main St"}))],
        testContext,
      )
      Callback.phase1(
        [encodeShipOrderEvent(ShipmentCreated({orderId: "ord-1"}))],
        testContext,
      )
      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }
      await Callback.phase2(mockPublish)
      expect(publishedCommands.contents->Array.length)->toBe(0)
    })

    testPromise("items where process returns None are skipped", async () => {
      let json = encodeSkipProcessEvent(OrderPlaced({orderId: "ord-1"}))
      SkipCallback.phase1([json], testContext)
      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }
      await SkipCallback.phase2(mockPublish)
      expect(publishedCommands.contents->Array.length)->toBe(0)
      let row = SkipCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row.status)->toBe(Pending)
    })

    testPromise("empty TODO list produces no commands", async () => {
      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }
      await Callback.phase2(mockPublish)
      expect(publishedCommands.contents->Array.length)->toBe(0)
    })

    testPromise("publishJsons failure marks items as Failed", async () => {
      Callback.phase1(
        [encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "123 Main St"}))],
        testContext,
      )
      let failingPublish: ReventlessInfra.CommandTopic.publishJsons = async _cmds => {
        JsError.throwWithMessage("publish failed")
      }
      await Callback.phase2(failingPublish)
      let row = Callback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row.status)->toBe(Failed)
      expect(row.retryCount)->toBe(1)
    })

    testPromise("failed items with retryCount < maxRetries are retried", async () => {
      Callback.phase1(
        [encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "123 Main St"}))],
        testContext,
      )
      let failingPublish: ReventlessInfra.CommandTopic.publishJsons = async _cmds => {
        JsError.throwWithMessage("publish failed")
      }
      await Callback.phase2(failingPublish)
      let row1 = Callback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row1.retryCount)->toBe(1)

      let publishedCommands = ref([])
      let successPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }
      await Callback.phase2(successPublish)
      expect(publishedCommands.contents->Array.length)->toBe(1)
      let row2 = Callback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row2.status)->toBe(Processing)
    })
  })

  describe("full lifecycle", () => {
    testPromise("collect → process → resolve completes the TODO item", async () => {
      Callback.phase1(
        [encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "123 Main St"}))],
        testContext,
      )
      expect((Callback.todoItems->Dict.get("ord-1")->Option.getOrThrow).status)->toBe(Pending)

      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }
      await Callback.phase2(mockPublish)
      expect(publishedCommands.contents->Array.length)->toBe(1)
      expect((Callback.todoItems->Dict.get("ord-1")->Option.getOrThrow).status)->toBe(Processing)

      Callback.phase1(
        [encodeShipOrderEvent(ShipmentCreated({orderId: "ord-1"}))],
        testContext,
      )
      expect((Callback.todoItems->Dict.get("ord-1")->Option.getOrThrow).status)->toBe(Completed)

      let publishedCommands2 = ref([])
      let mockPublish2: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands2 := cmds
      }
      await Callback.phase2(mockPublish2)
      expect(publishedCommands2.contents->Array.length)->toBe(0)
    })
  })
})
