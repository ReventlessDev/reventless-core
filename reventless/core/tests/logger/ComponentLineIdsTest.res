// A component's log line carries the ids of the message it is about: its own msgId, its flow's
// correlationId and its causationId, and the entity a command is handled for. They come from the
// message, not from the invocation, so two commands of different flows in one batch keep their
// own, also on the lines that run on a fiber of their own.

open JestGlobals

let capture = async (run: unit => promise<unit>): array<Logger.record> => {
  let lines = []
  let remove = Logger.addSink(r => lines->Array.push(r))
  await run()
  remove()
  lines
}

let field = (r: Logger.record, k: string) => r.annotations->Dict.get(k)

let meta = (~msgId, ~correlationId, ~causationId=?): Message.meta => {
  ...AggregateFixtures.testMeta,
  msgId,
  correlationId,
  ?causationId,
}

describe("the log call carries a message's ids", () => {
  testPromise("a line on a fiber of its own keeps the ids it was given", async () => {
    let lines = await capture(
      async () =>
        EffectLogger.logInfo(
          ~comp="Aggregate(Order)",
          ~ids=EffectLogger.idsOf(
            meta(~msgId="m-1", ~correlationId="flow-1", ~causationId="e-0"),
            ~entityId="o-1",
            ~entityType="Order",
          ),
          "deciding",
        )->Effect.runSync,
    )
    let line = lines->Array.find(r => r.message == "deciding")->Option.getOrThrow
    expect(
      ["msgId", "correlationId", "causationId", "entityId", "entityType"]->Array.map(
        k => line->field(k),
      ),
    )->toEqual([Some("m-1"), Some("flow-1"), Some("e-0"), Some("o-1"), Some("Order")])
  })

  testPromise("the message's flow wins over the one the invocation annotated", async () => {
    let lines = await capture(
      async () =>
        EffectLogger.logInfo(
          ~ids=EffectLogger.idsOf(meta(~msgId="m-2", ~correlationId="flow-2")),
          "deciding",
        )
        ->Runtime.annotateInvocation(~correlationId="flow-of-the-batch", ~comp="Aggregate(Order)")
        ->Effect.runSync,
    )
    let line = lines->Array.find(r => r.message == "deciding")->Option.getOrThrow
    expect(line->field("correlationId"))->toEqual(Some("flow-2"))
    expect(line.comp)->toEqual(Some("Aggregate(Order)"))
  })
})

describe("component lines in a batch of several flows", () => {
  let _ = beforeEach(() => AggregateFixtures.mock.reset())

  testPromise("each command's aggregate lines carry its own ids and its entity", async () => {
    let item = (reference, flow) => {
      let i = AggregateFixtures.makeTopicItem(
        reference,
        AggregateFixtures.AggSpec.Create({name: "Widget"}),
      )
      {
        ...i,
        command: {
          ...i.command,
          meta: meta(~msgId=`m-${reference}`, ~correlationId=flow, ~causationId=`e-${reference}`),
        },
      }
    }
    let lines = await capture(
      async () => {
        let _ = await Stream.fromIterable([item("1", "flow-a"), item("2", "flow-b")])
        ->AggregateFixtures.TestHandler.handleCommands
        ->Effect.runPromise
      },
    )
    let deciding = lines->Array.filter(r => r.message->String.startsWith("handling command"))
    expect(deciding->Array.map(r => (r->field("msgId"), r->field("correlationId"))))->toEqual([
      (Some("m-1"), Some("flow-a")),
      (Some("m-2"), Some("flow-b")),
    ])
    expect(deciding->Array.map(r => (r->field("entityId"), r->field("entityType"))))->toEqual([
      (Some("agg-1"), Some("TestAggregate")),
      (Some("agg-1"), Some("TestAggregate")),
    ])
  })
})
