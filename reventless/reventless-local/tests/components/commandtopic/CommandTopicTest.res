// Integration tests for CommandTopic_Builder with in-memory channel.

open TestFixtures
open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect
open CommandTopicFixtures

describe("CommandTopic (in-memory)", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await cmdTopic->ReventlessCore.Component.operations->TestRunner.resolve
  })

  testPromise("publishJsons succeeds without throwing", async () => {
    let ops = await cmdTopic->ReventlessCore.Component.operations->TestRunner.resolve
    let commandJson = ItemSpec.CreateItem({name: "Widget"})->ReventlessCore.Message.encode(ItemSpec.commandSchema)
    let didThrow = ref(false)
    try {
      await ops.publishJsons([{
        Reventless.Message.id: "item-1",
        meta: testMeta,
        commandJson,
      }])
    } catch {
    | _ => didThrow := true
    }
    expect(didThrow.contents)->toBe(false)
  })

  testPromise("publishJsons with empty array succeeds", async () => {
    let ops = await cmdTopic->ReventlessCore.Component.operations->TestRunner.resolve
    let didThrow = ref(false)
    try {
      await ops.publishJsons([])
    } catch {
    | _ => didThrow := true
    }
    expect(didThrow.contents)->toBe(false)
  })

  testPromise("publishJsons dispatches to bus channel (TestCommandTopicCmdTopic)", async () => {
    let ops = await cmdTopic->ReventlessCore.Component.operations->TestRunner.resolve
    // Verify the bus receives the command on the expected channel.
    // Channel name = make name ++ ComponentType.toName(CommandTopic) = "TestCommandTopic" ++ "CmdTopic"
    let received: ref<bool> = ref(false)
    Bus.registerCommandHandler("TestCommandTopicCmdTopic", async (_json, _ctx) => {
      received := true
    })
    let commandJson = ItemSpec.DeleteItem({id: "item-99"})->ReventlessCore.Message.encode(ItemSpec.commandSchema)
    await ops.publishJsons([{
      Reventless.Message.id: "item-99",
      meta: testMeta,
      commandJson,
    }])
    expect(received.contents)->toBe(true)
  })
})
