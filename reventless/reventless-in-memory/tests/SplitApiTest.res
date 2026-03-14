// Integration tests for split API mode.
// Verifies that core and plugin schemas register into separate server instances
// with no cross-contamination.
//
// Tests the split routing pattern used by Platform.makePlatform(splitApi=true):
// - Core schema → GraphQL_ServerInstance (dedicated core server)
// - Plugin schema → GraphQL_Server singleton (default plugin server)
//
// MCP split is structurally identical (MCP_ServerInstance mirrors
// GraphQL_ServerInstance) but is not tested here due to Jest ESM
// compatibility issues with the MCP SDK dependency chain.

open AsyncTest
open AsyncTest.Expect

// Force side-effect import (creates core instance + registers schemas)
let coreGraphQL = SplitApiFixtures.coreGraphQL

// Core field names
let coreQueryFields = ["Core_Plugin", "Core_Plugins"]
let coreMutationFields = ["Core_Plugin_Activate", "Core_Plugin_Deactivate", "Core_Clone"]

// Plugin field names
let pluginMutationPrefix = "SplitTestPlugin_SplitTestItem_"
let pluginQueryPrefix = "SplitTestPlugin_SplitTestItem"

describe("Split API Mode — Schema Separation", () => {
  describe("Plugin GraphQL singleton", () => {
    testPromise("contains plugin mutation fields", async () => {
      let d = GraphQL_Server.diagnostics()
      let hasPluginMutation =
        d.registeredMutationFields->Array.some(f => f->String.startsWith(pluginMutationPrefix))
      expect(hasPluginMutation)->toBe(true)
    })

    testPromise("contains plugin query fields", async () => {
      let d = GraphQL_Server.diagnostics()
      let hasPluginQuery =
        d.registeredQueryFields->Array.some(f => f->String.startsWith(pluginQueryPrefix))
      expect(hasPluginQuery)->toBe(true)
    })

    testPromise("does NOT contain core mutation fields", async () => {
      let d = GraphQL_Server.diagnostics()
      let hasCoreField =
        d.registeredMutationFields->Array.some(f =>
          coreMutationFields->Array.includes(f)
        )
      expect(hasCoreField)->toBe(false)
    })

    testPromise("does NOT contain core query fields", async () => {
      let d = GraphQL_Server.diagnostics()
      let hasCoreQuery =
        d.registeredQueryFields->Array.some(f =>
          coreQueryFields->Array.includes(f)
        )
      expect(hasCoreQuery)->toBe(false)
    })
  })

  describe("Core GraphQL instance", () => {
    testPromise("contains core mutation fields", async () => {
      let d = coreGraphQL.diagnostics()
      coreMutationFields->Array.forEach(field => {
        let hasField = d.registeredMutationFields->Array.includes(field)
        expect(hasField)->toBe(true)
      })
    })

    testPromise("contains core query fields", async () => {
      let d = coreGraphQL.diagnostics()
      coreQueryFields->Array.forEach(field => {
        let hasField = d.registeredQueryFields->Array.includes(field)
        expect(hasField)->toBe(true)
      })
    })

    testPromise("does NOT contain plugin mutation fields", async () => {
      let d = coreGraphQL.diagnostics()
      let hasPluginMutation =
        d.registeredMutationFields->Array.some(f => f->String.startsWith(pluginMutationPrefix))
      expect(hasPluginMutation)->toBe(false)
    })

    testPromise("does NOT contain plugin query fields", async () => {
      let d = coreGraphQL.diagnostics()
      let hasPluginQuery =
        d.registeredQueryFields->Array.some(f => f->String.startsWith(pluginQueryPrefix))
      expect(hasPluginQuery)->toBe(false)
    })

    testPromise("has core type definitions registered", async () => {
      let d = coreGraphQL.diagnostics()
      expect(d.typeCount > 0)->toBe(true)
    })

    testPromise("has no SDL mismatches", async () => {
      let d = coreGraphQL.diagnostics()
      expect(d.mismatches->Array.length)->toBe(0)
    })
  })
})
