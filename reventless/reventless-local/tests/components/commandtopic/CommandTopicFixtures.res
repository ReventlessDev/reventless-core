// Integration test fixtures for CommandTopic builder (in-memory).

module ItemSpec = {
  module Id = Reventless.Id.String
  let name = "TestCommandTopicItem"

  @schema
  type command = | CreateItem({name: string}) | DeleteItem({id: string})

  @schema
  type event = | ItemCreated({name: string})

  @schema
  type error = | AlreadyExists

  let moduleUrl: string = %raw(`import.meta.url`)
}

// ─────────────────────────────────────────────────────────────
// Bus and Pulumi setup
// ─────────────────────────────────────────────────────────────

module Bus = LocalBus.Make()

let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build CommandTopic using in-memory channel
// ─────────────────────────────────────────────────────────────

module CommandTopicMaker = ReventlessCore.CommandTopic_Builder.Make(
  ItemSpec,
  LocalCommandTopicChannel.Make(Bus),
)

let cmdTopic = CommandTopicMaker.make(~name="TestCommandTopic")

