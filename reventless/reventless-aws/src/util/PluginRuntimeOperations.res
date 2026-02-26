let operations: ReventlessCore.PluginRuntimeOperations.operations = {
  topicSubscription: {
    subscribeChannelToTopic: Util_TopicSubscription_Runtime.subscribe,
    unsubscribeChannelFromTopic: Util_TopicSubscription_Runtime.unsubscribe,
  },
  messagePublish: {
    sendMessageToChannel: Util_PluginMessage_Runtime.sendMessage,
  },
}
