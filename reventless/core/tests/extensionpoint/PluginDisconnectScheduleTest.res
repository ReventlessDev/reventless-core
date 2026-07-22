// Guards the disconnect schedule's rule name. Create and delete must derive it
// identically: they previously did not — create prefixed `Spec.environment`,
// delete did not — so every delete targeted a rule that had never been created
// and the real rule survived. The leak is invisible at runtime, because the
// delete reports success against a name AWS simply doesn't have.

open JestGlobals

let created: ref<array<string>> = ref([])
let deleted: ref<array<string>> = ref([])

module DisconnectSpec = {
  let runtimeOps: PluginRuntimeOperations.operations = {
    messagePublish: {
      sendMessageToChannel: async (~channelId as _, ~messageBody as _) => (),
    },
  }
  let environment = "teststack"
  let updateApiSchema = None
  let manageSubscriptions = None
}

module EP = PluginExtensionPoint_Plugin.Make(DisconnectSpec)

let createSchedule: Reventless.Schedule.create = async schedule => {
  created := created.contents->Array.concat([schedule.name])
}

let deleteSchedule: Reventless.Schedule.delete = async name => {
  deleted := deleted.contents->Array.concat([name])
}

let queryEngine: Reventless.QueryEngine.operations = {
  scan: async (~readModelName as _, ~filterConfigs as _, ~limit as _) => [],
  query: async (
    ~readModelName as _,
    ~key as _=?,
    ~id as _,
    ~subIdConfig as _=?,
    ~filterConfigs as _=?,
    ~ascending as _=?,
    ~limit as _=?,
  ) => [],
}

let pluginId = "Catalog_1.0.0-alpha.169"

let handle = directive => EP.directiveHandler(createSchedule, deleteSchedule, queryEngine, directive)

describe("plugin disconnect schedule", () => {
  test("create and delete address the same rule name", async () => {
    created := []
    deleted := []
    await handle(ReventlessInfra.PluginExtensionPointSpec.CreateDisconnectSchedule(pluginId, 5))
    await handle(DeleteDisconnectSchedule(pluginId))
    expect(deleted.contents)->toEqual(created.contents)
  })

  test("the rule name is namespaced by stack", async () => {
    created := []
    await handle(ReventlessInfra.PluginExtensionPointSpec.CreateDisconnectSchedule(pluginId, 5))
    // Several stacks share one EventBridge bus, so a bare plugin id would
    // collide across them.
    expect(created.contents)->toEqual(["teststack-" ++ pluginId])
  })
})
