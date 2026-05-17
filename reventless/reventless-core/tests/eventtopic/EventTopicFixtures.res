
// Test event spec for EventTopic
module ItemEventTopicSpec = {
  module Id = Reventless.Id.StringPure
  let name = "TestItemEventTopic"

  @schema
  type event = | ItemPublished({name: string}) | ItemRemoved({id: string})
}

// Captured publish calls
let capturedCalls: ref<array<(string, Message.meta, JSON.t)>> = ref([])

let mockPublishJson: EventTopic.publishJson = async (service, meta, json) => {
  capturedCalls := capturedCalls.contents->Array.concat([(service, meta, json)])
}

let testMeta: Message.meta = {
  service: "test",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}

let makeEvent' = (id, event) => ({
  Reventless.Message.id,
  meta: testMeta,
  event,
}: Message.event'<string, ItemEventTopicSpec.event>)

let reset = () => {
  capturedCalls := []
}
