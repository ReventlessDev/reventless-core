// Integration tests for CommandGenerator_Builder (in-memory).
// Verifies that makeHandler returns a resolver that generates and publishes commands.

open JestGlobals
open CommandGeneratorFixtures

describe("CommandGenerator_Builder.Make:", () => {
  let _ = beforeEach(() => resetMocks())

  describe("makeHandler:", () => {
    testPromise("CreateCGItem payload publishes correct commandJson", async () => {
      // Resolve the handler from the Output wrapper
      let handler = await CGMaker.makeHandler(~publishJsons=mockPublish, ~publishJsonsAndWait=None)->TestRunner.resolve

      // Build payload: arguments must include id AND the command fields (name).
      // generateCommand stringifies arguments, slices off id (index 0), uses the rest as params.
      let payload: ReventlessCore.CommandGenerator.payload = {
        command: "CreateCGItem",
        arguments: {"id": "item-1", "name": "widget"}->Obj.magic,
        meta: {ip: ["127.0.0.1"], user: "testuser", info: ""},
        identity: Reventless.Identity.anonymous,
      }

      // Call handler — generateCommand is async (awaits publishJsons internally)
      let _ = await handler(payload, ())->Effect.runPromise

      expect(capturedCmds.contents->Array.length)->toBe(1)

      let cmd = capturedCmds.contents->Array.getUnsafe(0)
      expect(cmd.id)->toBe("item-1")

      // commandJson should decode to CreateCGItem({name: "widget"})
      let decoded = cmd.commandJson->S.parseJsonOrThrow(CGSpec.commandSchema)
      expect(decoded)->toEqual(CGSpec.CreateCGItem({name: "widget"}))
    })

    testPromise("make creates a CommandGenerator component without throwing", async () => {
      let cg = CGMaker.make(~name="test-cg")
      let _ = cg
      expect(true)->toBe(true)
    })
  })
})
