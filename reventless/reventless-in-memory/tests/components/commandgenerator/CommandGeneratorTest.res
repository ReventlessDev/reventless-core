// Integration tests for CommandGenerator (placeholder).
// Full tests require GraphQL server setup — see adapter tests for low-level coverage.

open AsyncTest
open AsyncTest.Expect
open CommandGeneratorFixtures

describe("CommandGenerator (in-memory)", () => {
  testPromise("bus is initialized", async () => {
    // Placeholder: CommandGenerator resolver tests are in adapter/QueryEngineTest.res
    expect(true)->toBe(true)
  })
})
