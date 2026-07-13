// Projection GWT for the ApiFragments read model — one row per plugin name holding the
// current fragment + push status, projected off the ApiFragmentRegistry aggregate's events
// (event-sourced-fragment-registries plan). Keyed by the payload pluginId (not the singleton
// aggregate id). ApiSchemaComputed is the reactive-push trigger only — it must NOT touch a row.
open ReventlessCore
module P = Reventless.Plugin // P.Domain / P.Platform — avoid opening apiSchemaFragment's labels

module Test = ReventlessGwt.MultiSourceProjection_GWT.Make(ApiFragmentsProjection.ApiFragmentsMapping)
open Test
open ApiFragmentRegistrySpec

let fragment1: Reventless.Plugin.apiSchemaFragment = {
  encoded: `{"types":["type Catalog_Product { id: ID! }"],"mutations":[],"queries":[],"subscriptions":[],"subscriptionSources":[]}`,
  protocol: "graphql",
}

let fragment2: Reventless.Plugin.apiSchemaFragment = {
  encoded: `{"types":["type Catalog_Product { id: ID!\\n  name: String! }"],"mutations":[],"queries":[],"subscriptions":[],"subscriptionSources":[]}`,
  protocol: "graphql",
}

let registeredState: ApiFragmentsReadModelSpec.state = {
  pluginId: "p1",
  encoded: fragment1.encoded,
  protocol: fragment1.protocol,
  apiTarget: P.Domain,
  registeredAt: "t0",
  updatedAt: "t0",
  pushStatus: "pending",
  pushMessage: "",
  pushedAt: "",
}

describe("ApiFragments projection", () => {
  test("ApiFragmentRegistered creates the row pending (registeredAt = updatedAt = event `at`)", () =>
    givenEvents([])
    ->whenEvent(ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: P.Domain, at: "t0"}))
    ->thenStateWithId("p1", registeredState)
  )

  test("ApiSchemaComputed is ignored (no row change)", () =>
    givenEvents([ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: P.Domain, at: "t0"})])
    ->whenEvent(ApiSchemaComputed({snapshot: []}))
    ->thenStateWithId("p1", registeredState)
  )

  test("ApiFragmentPushRecorded(ok) marks the row ok with the push time", () =>
    givenEvents([ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: P.Domain, at: "t0"})])
    ->whenEvent(ApiFragmentPushRecorded({pluginId: "p1", ok: true, message: "", at: "t1"}))
    ->thenStateWithId("p1", {...registeredState, pushStatus: "ok", pushedAt: "t1"})
  )

  test("ApiFragmentPushRecorded(error) carries the message", () =>
    givenEvents([ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: P.Domain, at: "t0"})])
    ->whenEvent(ApiFragmentPushRecorded({pluginId: "p1", ok: false, message: "stitch failed", at: "t1"}))
    ->thenStateWithId(
      "p1",
      {...registeredState, pushStatus: "error", pushMessage: "stitch failed", pushedAt: "t1"},
    )
  )

  test("ApiFragmentUpdated replaces the fragment and resets the row to pending", () =>
    givenEvents([
      ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: P.Domain, at: "t0"}),
      ApiFragmentPushRecorded({pluginId: "p1", ok: true, message: "", at: "t1"}),
    ])
    ->whenEvent(
      ApiFragmentUpdated({
        pluginId: "p1",
        previousFragment: fragment1,
        newFragment: fragment2,
        apiTarget: P.Domain,
        at: "t2",
      }),
    )
    ->thenStateWithId(
      "p1",
      {
        ...registeredState,
        encoded: fragment2.encoded,
        updatedAt: "t2",
        pushStatus: "pending",
        pushMessage: "",
        pushedAt: "t1",
      },
    )
  )

  test("ApiFragmentUpdated carrying a new target moves the row to that API", () =>
    givenEvents([ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: P.Domain, at: "t0"})])
    ->whenEvent(
      ApiFragmentUpdated({
        pluginId: "p1",
        previousFragment: fragment1,
        newFragment: fragment1,
        apiTarget: P.Platform,
        at: "t1",
      }),
    )
    ->thenStateWithId("p1", {...registeredState, apiTarget: P.Platform, updatedAt: "t1"})
  )

  test("ApiFragmentDeregistered removes the row", () =>
    givenEvents([ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: P.Domain, at: "t0"})])
    ->whenEvent(ApiFragmentDeregistered({pluginId: "p1"}))
    ->thenNoState
  )
})
