type publishedEvent = {
  componentName: string,
  entityId: string,
  eventCount: int,
  eventsJson: array<JSON.t>,
  meta: Reventless.Message.meta,
  // Per-event metas, parallel to eventsJson. Populated by publishers whose
  // eventsJson entries do NOT carry the meta fields inline (DcbEventLog: bare
  // {TAG, ...data} payloads) so hook consumers can still correlate per event
  // (e.g. the local projection checkpoint resolves pending appends by msgId).
  // Aggregate EventLog eventsJson are flat stored events with meta at the top
  // level, so it omits this field.
  metas?: array<Reventless.Message.meta>,
}

type beforePublishHook = publishedEvent => promise<publishedEvent>
type afterPublishHook = publishedEvent => promise<unit>

/** Module-level hook called before events are published to EventTopic. None = passthrough (default). */
let beforePublishHook: ref<option<beforePublishHook>> = ref(None)

/** Module-level hook called after events are published to EventTopic. None = no-op (default). */
let afterPublishHook: ref<option<afterPublishHook>> = ref(None)

let registerBeforePublish = (hook: beforePublishHook) => {
  beforePublishHook.contents = Some(hook)
}

let registerAfterPublish = (hook: afterPublishHook) => {
  afterPublishHook.contents = Some(hook)
}

let clearPublishHooks = () => {
  beforePublishHook.contents = None
  afterPublishHook.contents = None
}
