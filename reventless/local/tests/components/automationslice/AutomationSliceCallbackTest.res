// Unit tests for AutomationSlice_Callback (Plan 04 mixed-source shape) —
// exercises per-source decode dispatch, context plumbing, and toTags
// validation.

open JestGlobals
open AutomationSliceFixtures

module Callback = ReventlessCore.AutomationSlice_Callback.Make(ShipOrderSpec, ShipOrderAutomation)

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
    testPromise(
      "OrderPlaced JSON creates a pending TODO item",
      async () => {
        let json = encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "123 Main St"}))
        await Callback.phase1([json], testContext, ~capabilities=Reventless.Capabilities.none)
        let items = Callback.todoItems
        expect(items->Dict.toArray->Array.length)->toBe(1)
        let row = items->Dict.get("ord-1")->Option.getOrThrow
        expect(row.status)->toBe(Pending)
        expect(row.retryCount)->toBe(0)
      },
    )

    testPromise(
      "duplicate OrderPlaced is idempotent",
      async () => {
        let j1 = encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "123 Main St"}))
        let j2 = encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "456 Oak Ave"}))
        await Callback.phase1([j1], testContext, ~capabilities=Reventless.Capabilities.none)
        await Callback.phase1([j2], testContext, ~capabilities=Reventless.Capabilities.none)
        expect(Callback.todoItems->Dict.toArray->Array.length)->toBe(1)
      },
    )

    testPromise(
      "multiple OrderPlaced events create multiple TODO items",
      async () => {
        let j1 = encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "123 Main St"}))
        let j2 = encodeShipOrderEvent(OrderPlaced({orderId: "ord-2", address: "456 Oak Ave"}))
        await Callback.phase1([j1, j2], testContext, ~capabilities=Reventless.Capabilities.none)
        expect(Callback.todoItems->Dict.toArray->Array.length)->toBe(2)
      },
    )

    testPromise(
      "ShipmentCreated does not create a TODO item",
      async () => {
        let json = encodeShipOrderEvent(ShipmentCreated({orderId: "ord-1"}))
        await Callback.phase1([json], testContext, ~capabilities=Reventless.Capabilities.none)
        expect(Callback.todoItems->Dict.toArray->Array.length)->toBe(0)
      },
    )
  })

  describe("Phase 1 — resolve", () => {
    testPromise(
      "ShipmentCreated marks pending TODO item as completed",
      async () => {
        await Callback.phase1(
          [encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "123 Main St"}))],
          testContext,
          ~capabilities=Reventless.Capabilities.none,
        )
        await Callback.phase1(
          [encodeShipOrderEvent(ShipmentCreated({orderId: "ord-1"}))],
          testContext,
          ~capabilities=Reventless.Capabilities.none,
        )
        let row = Callback.todoItems->Dict.get("ord-1")->Option.getOrThrow
        expect(row.status)->toBe(Completed)
      },
    )

    testPromise(
      "ShipmentCreated for unknown id is a no-op",
      async () => {
        await Callback.phase1(
          [encodeShipOrderEvent(ShipmentCreated({orderId: "unknown"}))],
          testContext,
          ~capabilities=Reventless.Capabilities.none,
        )
        expect(Callback.todoItems->Dict.toArray->Array.length)->toBe(0)
      },
    )
  })

  describe("Phase 2 — process", () => {
    testPromise(
      "pending items produce commands via publishJsons",
      async () => {
        await Callback.phase1(
          [encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "123 Main St"}))],
          testContext,
          ~capabilities=Reventless.Capabilities.none,
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
      },
    )

    testPromise(
      "completed items are not processed",
      async () => {
        await Callback.phase1(
          [encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "123 Main St"}))],
          testContext,
          ~capabilities=Reventless.Capabilities.none,
        )
        await Callback.phase1(
          [encodeShipOrderEvent(ShipmentCreated({orderId: "ord-1"}))],
          testContext,
          ~capabilities=Reventless.Capabilities.none,
        )
        let publishedCommands = ref([])
        let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
          publishedCommands := cmds
        }
        await Callback.phase2(mockPublish)
        expect(publishedCommands.contents->Array.length)->toBe(0)
      },
    )

    testPromise(
      "items where process returns None are skipped",
      async () => {
        let json = encodeSkipProcessEvent(OrderPlaced({orderId: "ord-1"}))
        await SkipCallback.phase1([json], testContext, ~capabilities=Reventless.Capabilities.none)
        let publishedCommands = ref([])
        let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
          publishedCommands := cmds
        }
        await SkipCallback.phase2(mockPublish)
        expect(publishedCommands.contents->Array.length)->toBe(0)
        let row = SkipCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
        expect(row.status)->toBe(Pending)
      },
    )

    testPromise(
      "empty TODO list produces no commands",
      async () => {
        let publishedCommands = ref([])
        let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
          publishedCommands := cmds
        }
        await Callback.phase2(mockPublish)
        expect(publishedCommands.contents->Array.length)->toBe(0)
      },
    )

    testPromise(
      "publishJsons failure marks items as Failed",
      async () => {
        await Callback.phase1(
          [encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "123 Main St"}))],
          testContext,
          ~capabilities=Reventless.Capabilities.none,
        )
        let failingPublish: ReventlessInfra.CommandTopic.publishJsons = async _cmds => {
          JsError.throwWithMessage("publish failed")
        }
        await Callback.phase2(failingPublish)
        let row = Callback.todoItems->Dict.get("ord-1")->Option.getOrThrow
        expect(row.status)->toBe(Failed)
        expect(row.retryCount)->toBe(1)
      },
    )

    testPromise(
      "failed items with retryCount < maxRetries are retried",
      async () => {
        await Callback.phase1(
          [encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "123 Main St"}))],
          testContext,
          ~capabilities=Reventless.Capabilities.none,
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
      },
    )
  })

  // A row used to leave the retry budget by falling out of phase2's filter, so
  // `Failed` meant both "will be retried" and "never again" and only the count
  // told them apart — against a ceiling that lives in the Spec, not in the row.
  describe("retry exhaustion", () => {
    let failingPublish: ReventlessInfra.CommandTopic.publishJsons = async _cmds =>
      JsError.throwWithMessage("publish failed")

    let collectOne = async () =>
      await Callback.phase1(
        [encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "123 Main St"}))],
        testContext,
        ~capabilities=Reventless.Capabilities.none,
      )

    let statusOf = id => (Callback.todoItems->Dict.get(id)->Option.getOrThrow).status

    testPromise(
      "the attempt that spends the budget writes Abandoned, not Failed",
      async () => {
        await collectOne()
        // ShipOrderSpec.maxRetries is 3: attempts at retryCount 0, 1 and 2 leave the
        // row retriable, and the third failure is the one that ends it.
        await Callback.phase2(failingPublish)
        expect(statusOf("ord-1"))->toBe(Failed)
        await Callback.phase2(failingPublish)
        expect(statusOf("ord-1"))->toBe(Failed)
        await Callback.phase2(failingPublish)
        expect(statusOf("ord-1"))->toBe(Abandoned)
        expect((Callback.todoItems->Dict.get("ord-1")->Option.getOrThrow).retryCount)->toBe(3)
      },
    )

    testPromise(
      "an abandoned row is not picked up again",
      async () => {
        await collectOne()
        await Callback.phase2(failingPublish)
        await Callback.phase2(failingPublish)
        await Callback.phase2(failingPublish)
        expect(statusOf("ord-1"))->toBe(Abandoned)

        // A pass that would have succeeded: the row must still not be attempted,
        // which is what makes the status a decision rather than a label.
        let published = ref([])
        await Callback.phase2(async cmds => published := cmds)
        expect(published.contents->Array.length)->toBe(0)
        expect(statusOf("ord-1"))->toBe(Abandoned)
        expect((Callback.todoItems->Dict.get("ord-1")->Option.getOrThrow).retryCount)->toBe(3)
      },
    )

    testPromise(
      "a row left stranded at the ceiling is normalised on the next pass",
      async () => {
        await collectOne()
        // What an older build wrote, and what a Spec that lowered maxRetries leaves
        // behind: Failed at the ceiling, which no pass would ever pick up or mark.
        let row = Callback.todoItems->Dict.get("ord-1")->Option.getOrThrow
        Callback.todoItems->Dict.set("ord-1", {...row, status: Failed, retryCount: 3})

        let published = ref([])
        await Callback.phase2(async cmds => published := cmds)
        expect(published.contents->Array.length)->toBe(0)
        expect(statusOf("ord-1"))->toBe(Abandoned)
      },
    )

    testPromise(
      "the row carries the ceiling its count is racing",
      async () => {
        await collectOne()
        expect((Callback.todoItems->Dict.get("ord-1")->Option.getOrThrow).maxRetries)->toEqual(
          Some(ShipOrderSpec.maxRetries),
        )
      },
    )
  })

  describe("full lifecycle", () => {
    testPromise(
      "collect → process → resolve completes the TODO item",
      async () => {
        await Callback.phase1(
          [encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "123 Main St"}))],
          testContext,
          ~capabilities=Reventless.Capabilities.none,
        )
        expect((Callback.todoItems->Dict.get("ord-1")->Option.getOrThrow).status)->toBe(Pending)

        let publishedCommands = ref([])
        let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
          publishedCommands := cmds
        }
        await Callback.phase2(mockPublish)
        expect(publishedCommands.contents->Array.length)->toBe(1)
        expect((Callback.todoItems->Dict.get("ord-1")->Option.getOrThrow).status)->toBe(Processing)

        await Callback.phase1(
          [encodeShipOrderEvent(ShipmentCreated({orderId: "ord-1"}))],
          testContext,
          ~capabilities=Reventless.Capabilities.none,
        )
        expect((Callback.todoItems->Dict.get("ord-1")->Option.getOrThrow).status)->toBe(Completed)

        let publishedCommands2 = ref([])
        let mockPublish2: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
          publishedCommands2 := cmds
        }
        await Callback.phase2(mockPublish2)
        expect(publishedCommands2.contents->Array.length)->toBe(0)
      },
    )
  })

  // A row keeps the event that created it, so the command sent for it continues
  // the event's flow; a row stored before rows kept one still runs.
  describe("the flow", () => {
    let withMeta = (json: JSON.t, ~msgId, ~correlationId) =>
      switch json {
      | Object(d) =>
        let meta: Reventless.Message.meta = {
          service: ShipOrderSource.name,
          time: "2026-01-01T00:00:00Z",
          user: "user-7",
          msgId,
          correlationId,
          traceparent: "00-trace-span-01",
        }
        d->Dict.set("meta", meta->Reventless.Util_Sury.toJson(Reventless.Message.metaSchema))
        JSON.Object(d)
      | other => other
      }

    testPromise(
      "the command derives its meta from the event that created the row",
      async () => {
        let json =
          encodeShipOrderEvent(OrderPlaced({orderId: "ord-1", address: "123 Main St"}))->withMeta(
            ~msgId="evt-1",
            ~correlationId="flow-1",
          )
        await Callback.phase1([json], testContext, ~capabilities=Reventless.Capabilities.none)
        expect((Callback.todoItems->Dict.getUnsafe("ord-1")).source)->toEqual(
          Some({
            ReventlessCore.Message.msgId: "evt-1",
            correlationId: "flow-1",
            user: "user-7",
            traceparent: "00-trace-span-01",
          }),
        )
        let published = ref([])
        await Callback.phase2(async cmds => published := cmds)
        let meta = (published.contents->Array.getUnsafe(0)).meta
        expect(meta.correlationId)->toBe("flow-1")
        expect(meta.causationId)->toEqual(Some("evt-1"))
        expect(meta.user)->toEqual(Some("user-7"))
        expect(meta.traceparent)->toEqual(Some("00-trace-span-01"))
        expect(meta.service)->toBe(ShipOrderSpec.targetName)
        expect(meta.msgId != "evt-1")->toBe(true)
      },
    )

    testPromise(
      "a stored row without a source decodes and starts a new flow",
      async () => {
        let stored = JSON.parseOrThrow(`{"item":{"orderId":"ord-9","address":"x"},"status":"Pending","createdAt":"2026-01-01T00:00:00Z","retryCount":0}`)
        let row = stored->Reventless.Util_Sury.fromJson(todoRowSchema)
        expect(row.source)->toEqual(None)
        Callback.todoItems->Dict.set("ord-9", row)
        let published = ref([])
        await Callback.phase2(async cmds => published := cmds)
        let meta = (published.contents->Array.getUnsafe(0)).meta
        expect(meta.causationId)->toEqual(None)
        expect(meta.correlationId)->toBe(meta.msgId)
      },
    )

    testSync(
      "a row with a source round-trips through its schema",
      () => {
        let row: todoRow = {
          item: JSON.Encode.object(Dict.make()),
          status: Pending,
          createdAt: "2026-01-01T00:00:00Z",
          retryCount: 0,
          source: {ReventlessCore.Message.msgId: "evt-1", correlationId: "flow-1"},
        }
        let json = row->Reventless.Util_Sury.toJson(todoRowSchema)
        expect(json->JSON.stringify->String.includes(`"source":{"msgId":"evt-1"`))->toBe(true)
        expect(json->Reventless.Util_Sury.fromJson(todoRowSchema))->toEqual(row)
      },
    )
  })
})
