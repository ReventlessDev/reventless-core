type publishedEvent = {
  componentName: string,
  entityId: string,
  eventCount: int,
  eventsJson: array<JSON.t>,
  meta: Reventless.Message.meta,
}

type beforePublishHook = publishedEvent => promise<publishedEvent>
type afterPublishHook = publishedEvent => promise<unit>

/** Module-level hook called before events are published to EventTopic. None = passthrough (default). */
let beforePublishHook: ref<option<beforePublishHook>> = ref(None)

/** Module-level hook called after events are published to EventTopic. None = no-op (default). */
let afterPublishHook: ref<option<afterPublishHook>> = ref(None)
