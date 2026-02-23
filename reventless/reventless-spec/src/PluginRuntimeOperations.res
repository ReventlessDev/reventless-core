// Provider-agnostic interface for plugin runtime operations

type topicSubscriptionOps = {
  subscribeChannelToTopic: (~channelId: string, ~topicId: string) => promise<unit>,
  unsubscribeChannelFromTopic: (~channelId: string, ~topicId: string) => promise<unit>,
}

type messagePublishOps = {
  sendMessageToChannel: (~channelId: string, ~messageBody: string) => promise<unit>,
}

type operations = {
  topicSubscription: topicSubscriptionOps,
  messagePublish: messagePublishOps,
}
