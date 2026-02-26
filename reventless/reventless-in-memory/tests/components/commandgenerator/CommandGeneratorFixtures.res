// Fixtures for CommandGenerator integration tests.
// CommandGenerator uses GraphQL resolvers — in-memory test verifies the resolver builder.

module Bus = InMemory_Bus.Make()
let _ = TestRunner.setup()
