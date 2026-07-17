// Fixtures for EventTopic.publishJsonStream tests (Phase I).

module ItemStreamSpec = {
  module Id = Reventless.Id.StringPure
  let name = "StreamEvtItem"

  @schema
  type event = | ItemPublished({name: string}) | ItemRemoved({id: string})
}

module StreamEvtBus = LocalBus.Make()

let _ = TestRunner.setup()

// Topic name = make name ++ "EventTopic" = "StreamEvtTopic" ++ "EventTopic"
let received: ref<int> = ref(0)
let _ = StreamEvtBus.subscribeToEvents("StreamEvtTopicEventTopic", async (_, _, _) => {
  received := received.contents + 1
})

module StreamEvtTopicMaker = ReventlessCore.EventTopic_Builder.Make(
  ItemStreamSpec,
  LocalEventTopicPublisher.Make(StreamEvtBus),
)

let evtTopic = StreamEvtTopicMaker.make(~name="StreamEvtTopic", ~storageResources=[])

