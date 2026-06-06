// Fixtures for CommandTopic.publishJsonsStream tests (Phase I).

open TestFixtures

module ItemSpec = {
  module Id = Reventless.Id.String
  let name = "StreamCmdItem"

  @schema
  type command = | CreateItem({name: string}) | DeleteItem({id: string})

  @schema
  type event = | ItemCreated({name: string})

  @schema
  type error = | AlreadyExists

  let moduleUrl: string = %raw(`import.meta.url`)
}

module StreamBus = LocalBus.Make()

let _ = TestRunner.setup()

module StreamCmdTopicMaker = ReventlessCore.CommandTopic_Builder.Make(
  ItemSpec,
  LocalCommandTopicChannel.Make(StreamBus),
)

let cmdTopic = StreamCmdTopicMaker.make(~name="StreamCmdTopic")

// Track dispatched commands per test — reset in beforeEach
let captured: ref<array<JSON.t>> = ref([])

let _ = StreamBus.registerCommandHandler("StreamCmdTopicCmdTopic", async (body, _ctx) => {
  captured := captured.contents->Array.concat([body])
})

let makeJson = (id): Reventless.Message.commandJson => {
  Reventless.Message.id: id,
  meta: testMeta,
  commandJson: ItemSpec.CreateItem({name: id})->ReventlessCore.Message.encode(ItemSpec.commandSchema),
}
