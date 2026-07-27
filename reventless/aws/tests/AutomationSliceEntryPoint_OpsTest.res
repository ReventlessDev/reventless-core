// Guards the typed cold-start core hoisted out of AutomationSliceEntryPoint.mjs
// — the entry point whose former shell had silently drifted from the reworked
// callback functors (single-applied curried Make, `todoItems.contents`, wrong
// phase1 shape) and threw on its first event:
//   - parseHandlerConfig — incl. the new `bodyModule` + `context` fields the
//     repaired wiring depends on.
//   - makeAutomationJsonEventsHandler — raw envelope JSONs + context into
//     phase 1, sync → awaited phase 2 → sync ordering.
//   - makeOutboundJsonEventsHandler — tolerant DcbDecode of the inner `event`
//     payload (non-consumed event types dropped silently), decoded events into
//     phase 1.

open JestGlobals

let str = JSON.Encode.string
let obj = pairs => JSON.Encode.object(Dict.fromArray(pairs))

describe("AutomationSliceEntryPoint_Ops.parseHandlerConfig", () => {
  testSync("empty raw config yields no handlers", () => {
    expect(AutomationSliceEntryPoint_Ops.parseHandlerConfig("")->Array.length)->toBe(0)
  })

  testSync("decodes a full entry incl. bodyModule and context", () => {
    let config = obj([
      (
        "handlers",
        JSON.Encode.array([
          obj([
            ("specModule", str("@x/plugin/src/Order/AutomationSlice/Restock.res.mjs")),
            ("bodyModule", str("@x/plugin/src/Order/AutomationSlice/Restock_Automation.res.mjs")),
            ("callbackType", str("automation")),
            ("queryDbTableName", str("RestockTodo-abc")),
            ("dcbQueueUrl", str("https://sqs/queue.fifo")),
            ("sourceUrn", str("arn:aws:dynamodb:eu-west-1:1:table/log/stream/x")),
            (
              "context",
              obj([
                ("environment", str("alpha")),
                ("platformName", str("OnlineShop")),
                ("pluginName", str("Ordering")),
                ("sliceName", str("Restock")),
              ]),
            ),
          ]),
        ]),
      ),
    ])->JSON.stringify
    let entries = AutomationSliceEntryPoint_Ops.parseHandlerConfig(config)
    expect(entries->Array.length)->toBe(1)
    let e = entries->Array.getUnsafe(0)
    expect(e.bodyModule)->toBe("@x/plugin/src/Order/AutomationSlice/Restock_Automation.res.mjs")
    expect(e.callbackType)->toBe("automation")
    expect(e.dcbQueueUrl)->toBe("https://sqs/queue.fifo")
    switch e.context {
    | Some(ctx) => {
        expect(ctx.environment)->toBe("alpha")
        expect(ctx.platformName)->toBe("OnlineShop")
        expect(ctx.pluginName)->toBe("Ordering")
        expect(ctx.sliceName)->toBe("Restock")
      }
    | None => JsError.throwWithMessage("expected Some(context)")
    }
  })

  testSync("a stale entry without bodyModule/context decodes with defaults", () => {
    let config = obj([
      (
        "handlers",
        JSON.Encode.array([
          obj([
            ("specModule", str("a.res.mjs")),
            ("callbackType", str("outbound")),
            ("queryDbTableName", str("t")),
            ("dcbQueueUrl", str("u")),
            ("sourceUrn", str("arn")),
          ]),
        ]),
      ),
    ])->JSON.stringify
    let e = AutomationSliceEntryPoint_Ops.parseHandlerConfig(config)->Array.getUnsafe(0)
    expect(e.bodyModule)->toBe("")
    expect(e.context->Option.isNone)->toBe(true)
  })
})

// Shared stubs — the pipelines only touch phase1/phase2 plus the injected
// sync/publish, so the callback records carry empty TODO dicts.
let noopPublish: ReventlessCore.CommandTopic.publishJsons = async _ => ()

describe("AutomationSliceEntryPoint_Ops.makeAutomationJsonEventsHandler", () => {
  test("passes raw envelope JSONs + context to phase 1; sync → phase 2 → sync", async () => {
    let steps = []
    let receivedJsons = ref([])
    let receivedCtx = ref(None)
    let callback: AutomationSliceEntryPoint_Ops.automationCallback = {
      todoItems: Dict.make(),
      phase1: (jsons, ctx) => {
        receivedJsons := jsons
        receivedCtx := Some(ctx)
        steps->Array.push("phase1")
      },
      phase2: async _publish => steps->Array.push("phase2"),
    }
    let context: Reventless.AutomationSlice.context = {
      environment: "test",
      platformName: "P",
      pluginName: "Pl",
      sliceName: "S",
    }
    let handler = AutomationSliceEntryPoint_Ops.makeAutomationJsonEventsHandler(
      ~context,
      ~callback,
      ~publishJsons=noopPublish,
      ~syncTodoItems=async () => steps->Array.push("sync"),
    )
    let envelope = obj([("meta", obj([("service", str("Order"))])), ("event", str("Placed"))])
    await Stream.fromIterable([envelope, str("bare")])->handler->Effect.runPromise
    // Raw JSONs — the callback unwraps envelopes itself.
    expect(receivedJsons.contents)->toEqual([envelope, str("bare")])
    expect(receivedCtx.contents->Option.map(c => c.Reventless.AutomationSlice.sliceName))->toEqual(
      Some("S"),
    )
    expect(steps)->toEqual(["phase1", "sync", "phase2", "sync"])
  })
})

// Consumed-event fixture for the outbound decode: one consumed variant with a
// payload, one payload-less, decoded from a source that also emits types this
// slice does not consume.
@schema
type outboundEvent =
  | OrderPlaced({orderId: string})
  | OrderArchived

describe("AutomationSliceEntryPoint_Ops.makeOutboundJsonEventsHandler", () => {
  test("decodes inner event payloads, drops non-consumed types silently", async () => {
    let steps = []
    let received = ref([])
    let callback: AutomationSliceEntryPoint_Ops.outboundCallback<outboundEvent> = {
      todoItems: Dict.make(),
      phase1: events => {
        received := events
        steps->Array.push("phase1")
      },
      phase2: async _publish => steps->Array.push("phase2"),
    }
    let handler = AutomationSliceEntryPoint_Ops.makeOutboundJsonEventsHandler(
      ~consumedEventSchema=outboundEventSchema,
      ~callback,
      ~publishJsons=noopPublish,
      ~syncTodoItems=async () => steps->Array.push("sync"),
    )
    let placed = obj([
      ("meta", obj([("service", str("Order"))])),
      ("event", obj([("TAG", str("OrderPlaced")), ("orderId", str("ord-1"))])),
    ])
    // Not consumed by this slice — dropped without an error.
    let ignored = obj([("event", obj([("TAG", str("OrderShipped")), ("orderId", str("ord-1"))]))])
    // Bare payload-less variant, no envelope.
    let archived = str("OrderArchived")
    await Stream.fromIterable([placed, ignored, archived])->handler->Effect.runPromise
    expect(received.contents)->toEqual([OrderPlaced({orderId: "ord-1"}), OrderArchived])
    expect(steps)->toEqual(["phase1", "sync", "phase2", "sync"])
  })
})
