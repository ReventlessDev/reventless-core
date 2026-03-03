// Unit tests for AutomationSlice_Callback — tests collect/resolve/process phases directly.

open AsyncTest
open AsyncTest.Expect
open AutomationSliceFixtures

module Callback = ReventlessCore.AutomationSlice_Callback.Make(ShipOrderSpec)
module SkipCallback = ReventlessCore.AutomationSlice_Callback.Make(SkipProcessSpec)

open ReventlessCore.AutomationSlice_Callback

describe("AutomationSlice Callback", () => {
  let _ = beforeEach(() => {
    Callback.todoItems := Dict.make()
    SkipCallback.todoItems := Dict.make()
  })

  describe("Phase 1 — collect", () => {
    testPromise("OrderPlaced event creates a pending TODO item", async () => {
      Callback.phase1([OrderPlaced({orderId: "ord-1", address: "123 Main St"})])
      let items = Callback.todoItems.contents
      expect(items->Dict.toArray->Array.length)->toBe(1)
      let row = items->Dict.get("ord-1")
      expect(row->Option.isSome)->toBe(true)
      let r = row->Option.getOrThrow
      expect(r.status)->toBe(Pending)
      expect(r.retryCount)->toBe(0)
    })

    testPromise("duplicate OrderPlaced does not create a second TODO item (idempotent)", async () => {
      Callback.phase1([OrderPlaced({orderId: "ord-1", address: "123 Main St"})])
      Callback.phase1([OrderPlaced({orderId: "ord-1", address: "456 Oak Ave"})])
      let items = Callback.todoItems.contents
      expect(items->Dict.toArray->Array.length)->toBe(1)
    })

    testPromise("multiple different OrderPlaced events create multiple TODO items", async () => {
      Callback.phase1([
        OrderPlaced({orderId: "ord-1", address: "123 Main St"}),
        OrderPlaced({orderId: "ord-2", address: "456 Oak Ave"}),
      ])
      let items = Callback.todoItems.contents
      expect(items->Dict.toArray->Array.length)->toBe(2)
    })

    testPromise("ShipmentCreated event does not create a TODO item", async () => {
      Callback.phase1([ShipmentCreated({orderId: "ord-1"})])
      let items = Callback.todoItems.contents
      expect(items->Dict.toArray->Array.length)->toBe(0)
    })
  })

  describe("Phase 1 — resolve", () => {
    testPromise("ShipmentCreated marks pending TODO item as completed", async () => {
      Callback.phase1([OrderPlaced({orderId: "ord-1", address: "123 Main St"})])
      Callback.phase1([ShipmentCreated({orderId: "ord-1"})])
      let row = Callback.todoItems.contents->Dict.get("ord-1")->Option.getOrThrow
      expect(row.status)->toBe(Completed)
    })

    testPromise("ShipmentCreated for unknown id is a no-op", async () => {
      Callback.phase1([ShipmentCreated({orderId: "unknown"})])
      let items = Callback.todoItems.contents
      expect(items->Dict.toArray->Array.length)->toBe(0)
    })
  })

  describe("Phase 2 — process", () => {
    testPromise("pending items produce commands via publishJsons", async () => {
      Callback.phase1([OrderPlaced({orderId: "ord-1", address: "123 Main St"})])
      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }
      await Callback.phase2(mockPublish)

      expect(publishedCommands.contents->Array.length)->toBe(1)
      let cmd = publishedCommands.contents->Array.getUnsafe(0)
      expect(cmd.id)->toBe("ord-1")

      // Item should be in Processing status after phase2
      let row = Callback.todoItems.contents->Dict.get("ord-1")->Option.getOrThrow
      expect(row.status)->toBe(Processing)
    })

    testPromise("completed items are not processed", async () => {
      Callback.phase1([OrderPlaced({orderId: "ord-1", address: "123 Main St"})])
      Callback.phase1([ShipmentCreated({orderId: "ord-1"})])
      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }
      await Callback.phase2(mockPublish)
      expect(publishedCommands.contents->Array.length)->toBe(0)
    })

    testPromise("items where process returns None are skipped", async () => {
      SkipCallback.phase1([OrderPlaced({orderId: "ord-1", address: "123 Main St"})])
      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }
      await SkipCallback.phase2(mockPublish)
      expect(publishedCommands.contents->Array.length)->toBe(0)
      // Item stays Pending when process returns None
      let row = SkipCallback.todoItems.contents->Dict.get("ord-1")->Option.getOrThrow
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
      Callback.phase1([OrderPlaced({orderId: "ord-1", address: "123 Main St"})])
      let failingPublish: ReventlessInfra.CommandTopic.publishJsons = async _cmds => {
        JsError.throwWithMessage("publish failed")
      }
      await Callback.phase2(failingPublish)
      let row = Callback.todoItems.contents->Dict.get("ord-1")->Option.getOrThrow
      expect(row.status)->toBe(Failed)
      expect(row.retryCount)->toBe(1)
    })

    testPromise("failed items with retryCount < maxRetries are retried", async () => {
      Callback.phase1([OrderPlaced({orderId: "ord-1", address: "123 Main St"})])
      // First attempt fails
      let failingPublish: ReventlessInfra.CommandTopic.publishJsons = async _cmds => {
        JsError.throwWithMessage("publish failed")
      }
      await Callback.phase2(failingPublish)
      let row1 = Callback.todoItems.contents->Dict.get("ord-1")->Option.getOrThrow
      expect(row1.retryCount)->toBe(1)

      // Second attempt succeeds
      let publishedCommands = ref([])
      let successPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }
      await Callback.phase2(successPublish)
      expect(publishedCommands.contents->Array.length)->toBe(1)
      let row2 = Callback.todoItems.contents->Dict.get("ord-1")->Option.getOrThrow
      expect(row2.status)->toBe(Processing)
    })
  })

  describe("full lifecycle", () => {
    testPromise("collect → process → resolve completes the TODO item", async () => {
      // 1. Collect
      Callback.phase1([OrderPlaced({orderId: "ord-1", address: "123 Main St"})])
      expect((Callback.todoItems.contents->Dict.get("ord-1")->Option.getOrThrow).status)->toBe(
        Pending,
      )

      // 2. Process
      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }
      await Callback.phase2(mockPublish)
      expect(publishedCommands.contents->Array.length)->toBe(1)
      expect((Callback.todoItems.contents->Dict.get("ord-1")->Option.getOrThrow).status)->toBe(
        Processing,
      )

      // 3. Resolve
      Callback.phase1([ShipmentCreated({orderId: "ord-1"})])
      expect((Callback.todoItems.contents->Dict.get("ord-1")->Option.getOrThrow).status)->toBe(
        Completed,
      )

      // 4. No more processing after completion
      let publishedCommands2 = ref([])
      let mockPublish2: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands2 := cmds
      }
      await Callback.phase2(mockPublish2)
      expect(publishedCommands2.contents->Array.length)->toBe(0)
    })
  })
})
