// StateChangeSlice GWT for the ApiFragmentRegistry write side (the platform API-schema
// fragment registry replacing the deploy-schema:* keyspace —
// event-sourced-fragment-registries plan).
open ReventlessCore
open Reventless.Plugin // Domain / Platform constructors of apiTarget

module Test = ReventlessGwt.Behavior_GWT.Make(ApiFragmentRegistry, ApiFragmentRegistry_Behavior)
open Test
open ApiFragmentRegistry

let fragment1: Reventless.Plugin.apiSchemaFragment = {
  encoded: `{"types":["type Catalog_Product { id: ID! }"],"mutations":[],"queries":[],"subscriptions":[],"subscriptionSources":[]}`,
  protocol: "graphql",
}

let fragment2: Reventless.Plugin.apiSchemaFragment = {
  encoded: `{"types":["type Catalog_Product { id: ID!\\n  name: String! }"],"mutations":[],"queries":[],"subscriptions":[],"subscriptionSources":[]}`,
  protocol: "graphql",
}

describe("ApiFragmentRegistry StateChangeSlice", () => {
  test("register on empty state emits ApiFragmentRegistered", () =>
    givenEvents([])
    ->whenCmd(RegisterApiFragment({pluginId: "p1", fragment: fragment1, apiTarget: Domain, at: "t0"}))
    ->thenEvent(ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: Domain, at: "t0"}))
  )

  test("re-registering an identical fragment + target is idempotent (no event)", () =>
    givenEvents([ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: Domain, at: "t0"})])
    ->whenCmd(RegisterApiFragment({pluginId: "p1", fragment: fragment1, apiTarget: Domain, at: "t1"}))
    ->thenNoEvent
  )

  test("registering a changed fragment emits ApiFragmentUpdated (version supersession)", () =>
    givenEvents([ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: Domain, at: "t0"})])
    ->whenCmd(RegisterApiFragment({pluginId: "p1", fragment: fragment2, apiTarget: Domain, at: "t1"}))
    ->thenEvent(
      ApiFragmentUpdated({
        pluginId: "p1",
        previousFragment: fragment1,
        newFragment: fragment2,
        apiTarget: Domain,
        at: "t1",
      }),
    )
  )

  test("retargeting a plugin with an identical fragment emits ApiFragmentUpdated", () =>
    givenEvents([ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: Domain, at: "t0"})])
    ->whenCmd(RegisterApiFragment({pluginId: "p1", fragment: fragment1, apiTarget: Platform, at: "t1"}))
    ->thenEvent(
      ApiFragmentUpdated({
        pluginId: "p1",
        previousFragment: fragment1,
        newFragment: fragment1,
        apiTarget: Platform,
        at: "t1",
      }),
    )
  )

  test("deregister emits ApiFragmentDeregistered", () =>
    givenEvents([ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: Domain, at: "t0"})])
    ->whenCmd(DeregisterApiFragment({pluginId: "p1"}))
    ->thenEvent(ApiFragmentDeregistered({pluginId: "p1"}))
  )

  test("deregistering an absent fragment is idempotent (no event)", () =>
    givenEvents([])
    ->whenCmd(DeregisterApiFragment({pluginId: "p1"}))
    ->thenNoEvent
  )

  test("recording a push outcome emits ApiFragmentPushRecorded", () =>
    givenEvents([ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: Domain, at: "t0"})])
    ->whenCmd(RecordApiFragmentPush({pluginId: "p1", ok: true, message: "", at: "t1"}))
    ->thenEvent(ApiFragmentPushRecorded({pluginId: "p1", ok: true, message: "", at: "t1"}))
  )

  test("redelivering an identical push record is idempotent (no event)", () =>
    givenEvents([
      ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: Domain, at: "t0"}),
      ApiFragmentPushRecorded({pluginId: "p1", ok: true, message: "", at: "t1"}),
    ])
    ->whenCmd(RecordApiFragmentPush({pluginId: "p1", ok: true, message: "", at: "t1"}))
    ->thenNoEvent
  )

  test("a later distinct push outcome is recorded again", () =>
    givenEvents([
      ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: Domain, at: "t0"}),
      ApiFragmentPushRecorded({pluginId: "p1", ok: true, message: "", at: "t1"}),
    ])
    ->whenCmd(RecordApiFragmentPush({pluginId: "p1", ok: false, message: "stitch failed", at: "t2"}))
    ->thenEvent(ApiFragmentPushRecorded({pluginId: "p1", ok: false, message: "stitch failed", at: "t2"}))
  )

  test("recording a push for an unregistered plugin is dropped (no event)", () =>
    givenEvents([])
    ->whenCmd(RecordApiFragmentPush({pluginId: "p1", ok: true, message: "", at: "t1"}))
    ->thenNoEvent
  )
})
