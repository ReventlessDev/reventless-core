// Provider-agnostic interface for plugin runtime operations.
//
// Phase 3 of the plugin-eventcollector-runtime-rewire plans moved cross-plugin
// SNS subscription management to the admin EventCollector
// (manageSubscriptions hook in PluginExtensionPoint_Plugin.Spec). The plugin
// side no longer subscribes / unsubscribes anything at runtime, so the prior
// `topicSubscription` operations have been removed.

type messagePublishOps = {
  sendMessageToChannel: (~channelId: string, ~messageBody: string) => promise<unit>,
}

type operations = {
  messagePublish: messagePublishOps,
}
