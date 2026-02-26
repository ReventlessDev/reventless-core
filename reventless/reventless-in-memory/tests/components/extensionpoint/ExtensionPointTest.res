// Integration tests for ExtensionPoint builder (in-memory).
// Dispatches a command to the EP channel and verifies that publishToAggregates is called.

open AsyncTest
open AsyncTest.Expect
open ExtensionPointFixtures

// ─────────────────────────────────────────────────────────────
// Resolve Output chain before tests run.
//
// Two resolves are needed:
//   1. commandTopic resolve — triggers commandTopicResources->flatMap which calls
//      forCommandTopic → RuntimeEnvironment.make (starts handler chain) → connect
//      (registers Bus command handler).
//   2. eventTopic resolve — drains additional microtask ticks so the inner
//      handler->Output.apply(setHandlerRef) completes before any test dispatches.
// ─────────────────────────────────────────────────────────────

let _ = beforeAllAsync(async () => {
  let epOutputs = ep->TestEP.outputs
  let _ = await epOutputs.commandTopic->TestRunner.resolve
  let _ = await epOutputs.eventTopic->TestRunner.resolve
})

describe("ExtensionPoint (in-memory)", () => {
  let _ = beforeEach(() => resetMocks())

  testPromise(
    "dispatching Forward command calls publishToAggregates with Execute command",
    async () => {
      // Build the full command body: {id, meta, command}
      let forwardCmdJson =
        TestEPSpec.Forward({targetId: "target-1"})
        ->S.reverseConvertToJsonOrThrow(TestEPSpec.commandSchema)
      let body = JSON.Encode.object(
        Dict.fromArray([
          ("id", JSON.Encode.string("ep-id-1")),
          ("meta", testMeta->S.reverseConvertToJsonOrThrow(Reventless.Message.metaSchema)),
          ("command", forwardCmdJson),
        ]),
      )
      // Dispatch to the EP's CommandTopic channel: Spec.name + "ExtPoint" + "CmdTopic"
      await Bus.dispatchCommand("TestEPExtPointCmdTopic", body)

      // publishToAggregates["TargetAgg"] should have been called once
      expect(capturedCmds.contents->Array.length)->toBe(1)

      let cmd = capturedCmds.contents->Array.getUnsafe(0)
      // The aggregate command id comes from PublishCommand(targetId, ...) = "target-1"
      expect(cmd.id)->toBe("target-1")

      // commandJson should decode to Execute({targetId: "target-1"})
      let decoded = cmd.commandJson->S.parseJsonOrThrow(TargetAggSpec.commandSchema)
      expect(decoded)->toEqual(TargetAggSpec.Execute({targetId: "target-1"}))
    },
  )

  testPromise("unknown channel dispatch does not throw or call publishToAggregates", async () => {
    let body = JSON.Encode.object(Dict.fromArray([("id", JSON.Encode.string("x"))]))
    await Bus.dispatchCommand("UnknownChannel", body)
    expect(capturedCmds.contents->Array.length)->toBe(0)
  })
})
