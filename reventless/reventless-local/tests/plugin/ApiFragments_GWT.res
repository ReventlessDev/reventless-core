// StateViewSlice projection GWT for the ApiFragments read side — the current fragment
// per plugin name plus push status, replacing the deploy-schema:* rows as the durable
// stitch source (event-sourced-fragment-registries plan).
open ReventlessCore

module Test = ReventlessGwt.Projection_GWT.Make(ApiFragments, ApiFragments_Projection)
open Test
open ApiFragments

let fragment1: Reventless.Plugin.apiSchemaFragment = {
  encoded: `{"types":["type Catalog_Product { id: ID! }"],"mutations":[],"queries":[],"subscriptions":[],"subscriptionSources":[]}`,
  protocol: "graphql",
}

let fragment2: Reventless.Plugin.apiSchemaFragment = {
  encoded: `{"types":["type Catalog_Product { id: ID!\\n  name: String! }"],"mutations":[],"queries":[],"subscriptions":[],"subscriptionSources":[]}`,
  protocol: "graphql",
}

let registeredState: ApiFragments.state = {
  pluginId: "p1",
  encoded: fragment1.encoded,
  protocol: fragment1.protocol,
  registeredAt: "t0",
  updatedAt: "t0",
  pushStatus: "pending",
  pushMessage: "",
  pushedAt: "",
}

describe("ApiFragments StateViewSlice projection", () => {
  test("ApiFragmentRegistered creates the row pending (registeredAt = updatedAt = event time)", () =>
    givenEvents([])
    ->whenEvent(ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, at: "t0"}))
    ->thenStateWithId("p1", registeredState)
  )

  test("ApiFragmentPushRecorded(ok) marks the row ok with the push time", () =>
    givenEvents([ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, at: "t0"})])
    ->whenEvent(ApiFragmentPushRecorded({pluginId: "p1", ok: true, message: "", at: "t1"}))
    ->thenStateWithId("p1", {...registeredState, pushStatus: "ok", pushedAt: "t1"})
  )

  test("ApiFragmentPushRecorded(error) carries the message", () =>
    givenEvents([ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, at: "t0"})])
    ->whenEvent(
      ApiFragmentPushRecorded({pluginId: "p1", ok: false, message: "stitch failed", at: "t1"}),
    )
    ->thenStateWithId(
      "p1",
      {...registeredState, pushStatus: "error", pushMessage: "stitch failed", pushedAt: "t1"},
    )
  )

  test("ApiFragmentUpdated replaces the fragment and resets the row to pending", () =>
    givenEvents([
      ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, at: "t0"}),
      ApiFragmentPushRecorded({pluginId: "p1", ok: true, message: "", at: "t1"}),
    ])
    ->whenEvent(
      ApiFragmentUpdated({pluginId: "p1", previousFragment: fragment1, newFragment: fragment2, at: "t2"}),
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

  test("ApiFragmentDeregistered removes the row", () =>
    givenEvents([ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, at: "t0"})])
    ->whenEvent(ApiFragmentDeregistered({pluginId: "p1"}))
    ->thenNoState
  )
})
