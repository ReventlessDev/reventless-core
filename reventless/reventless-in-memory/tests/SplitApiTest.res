// Integration tests for split API mode.
// Verifies that admin and plugin schemas register into separate server instances
// with no cross-contamination.
//
// Tests the split routing pattern used by Platform.makePlatform(splitApi=true):
// - Admin schema → GraphQL_ServerInstance (dedicated admin server)
// - Plugin schema → GraphQL_Server singleton (default plugin server)
//
// MCP split is structurally identical (MCP_ServerInstance mirrors
// GraphQL_ServerInstance) but is not tested here due to Jest ESM
// compatibility issues with the MCP SDK dependency chain.

open AsyncTest
open AsyncTest.Expect

// Force side-effect import (creates admin instance + registers schemas)
let adminGraphQL = SplitApiFixtures.adminGraphQL

// Derive field names from schema entries — single source of truth.
let adminQueryFields = SplitApiFixtures.adminQueryFieldNames
let adminMutationFields = SplitApiFixtures.adminMutationFieldNames

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

    testPromise("does NOT contain admin mutation fields", async () => {
      let d = GraphQL_Server.diagnostics()
      let hasAdminField =
        d.registeredMutationFields->Array.some(f =>
          adminMutationFields->Array.includes(f)
        )
      expect(hasAdminField)->toBe(false)
    })

    testPromise("does NOT contain admin query fields", async () => {
      let d = GraphQL_Server.diagnostics()
      let hasAdminQuery =
        d.registeredQueryFields->Array.some(f =>
          adminQueryFields->Array.includes(f)
        )
      expect(hasAdminQuery)->toBe(false)
    })
  })

  describe("Admin GraphQL instance", () => {
    testPromise("contains admin mutation fields", async () => {
      let d = adminGraphQL.diagnostics()
      adminMutationFields->Array.forEach(field => {
        let hasField = d.registeredMutationFields->Array.includes(field)
        expect(hasField)->toBe(true)
      })
    })

    testPromise("contains admin query fields", async () => {
      let d = adminGraphQL.diagnostics()
      adminQueryFields->Array.forEach(field => {
        let hasField = d.registeredQueryFields->Array.includes(field)
        expect(hasField)->toBe(true)
      })
    })

    testPromise("does NOT contain plugin mutation fields", async () => {
      let d = adminGraphQL.diagnostics()
      let hasPluginMutation =
        d.registeredMutationFields->Array.some(f => f->String.startsWith(pluginMutationPrefix))
      expect(hasPluginMutation)->toBe(false)
    })

    testPromise("does NOT contain plugin query fields", async () => {
      let d = adminGraphQL.diagnostics()
      let hasPluginQuery =
        d.registeredQueryFields->Array.some(f => f->String.startsWith(pluginQueryPrefix))
      expect(hasPluginQuery)->toBe(false)
    })

    testPromise("has admin type definitions registered", async () => {
      let d = adminGraphQL.diagnostics()
      expect(d.typeCount > 0)->toBe(true)
    })

    testPromise("has no SDL mismatches", async () => {
      let d = adminGraphQL.diagnostics()
      expect(d.mismatches->Array.length)->toBe(0)
    })
  })
})
