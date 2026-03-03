// Plugin_Builder Spec for in-memory mode.
// Provides no-op runtime operations, identity resource naming, and "in-memory" environment.

let runtimeOps: ReventlessCore.PluginRuntimeOperations.operations = {
  topicSubscription: {
    subscribeChannelToTopic: (~channelId as _, ~topicId as _) => Promise.resolve(),
    unsubscribeChannelFromTopic: (~channelId as _, ~topicId as _) => Promise.resolve(),
  },
  messagePublish: {
    sendMessageToChannel: (~channelId as _, ~messageBody as _) => Promise.resolve(),
  },
}

let resourceNaming: ReventlessInfra.ResourceNaming.operations = {
  validateName: name => name,
  urnName: name => name,
}

let environment = "in-memory"
