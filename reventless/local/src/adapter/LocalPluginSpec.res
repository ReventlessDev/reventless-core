// Plugin_Builder Spec for the local platform.
// Provides no-op runtime operations, identity resource naming, and "local" environment.

let runtimeOps: ReventlessCore.PluginRuntimeOperations.operations = {
  messagePublish: {
    sendMessageToChannel: (~channelId as _, ~messageBody as _) => Promise.resolve(),
  },
}

let resourceNaming: ReventlessInfra.ResourceNaming.operations = {
  validateName: name => name,
  urnName: name => name,
}

let environment = "local"
let platformName = "local"
