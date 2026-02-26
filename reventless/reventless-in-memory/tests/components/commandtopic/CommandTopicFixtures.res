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
}

// ─────────────────────────────────────────────────────────────
// Bus and Pulumi setup
// ─────────────────────────────────────────────────────────────

module Bus = InMemory_Bus.Make()

let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build CommandTopic using in-memory channel
// ─────────────────────────────────────────────────────────────

module CommandTopicMaker = ReventlessCore.CommandTopic_Builder.Make(
  ItemSpec,
  CommandTopicChannel_InMemory.Make(Bus),
)

let cmdTopic = CommandTopicMaker.make(~name="TestCommandTopic")

// ─────────────────────────────────────────────────────────────
// Test metadata
// ─────────────────────────────────────────────────────────────

let testMeta: Reventless.Message.meta = {
  service: "test",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}
