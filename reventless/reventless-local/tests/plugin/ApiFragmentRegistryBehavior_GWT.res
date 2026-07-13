// Behavior GWT for the ApiFragmentRegistry SINGLETON AGGREGATE (the platform API-schema
// fragment registry — event-sourced-fragment-registries plan). Unlike the retired slice, the
// aggregate emits a SECOND event ApiSchemaComputed{snapshot} alongside each ApiFragment* fact,
// carrying the whole consistent per-plugin fragment set after the change (the reactive
// SideEffect's trigger). RecordApiFragmentPush changes no fragments, so it emits NO snapshot.
open ReventlessCore
module P = Reventless.Plugin // P.Domain / P.Platform — avoid shadowing apiSchemaFragment's labels

module Test = ReventlessGwt.Behavior_GWT.MakeFromAggregate(ApiFragmentRegistrySpec, ApiFragmentRegistryBehavior)
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

// A snapshot entry mirrors the behaviour's `snapshotOf` fold (pluginId + the fragment's
// encoded/protocol + its target).
let entry = (~pluginId, ~fragment: Reventless.Plugin.apiSchemaFragment, ~apiTarget): fragmentSnapshotEntry => {
  pluginId,
  encoded: fragment.encoded,
  protocol: fragment.protocol,
  apiTarget,
}

describe("ApiFragmentRegistry aggregate", () => {
  test("register on empty state emits ApiFragmentRegistered + ApiSchemaComputed", () =>
    givenEvents([])
    ->whenCmd(RegisterApiFragment({pluginId: "p1", fragment: fragment1, apiTarget: P.Domain, at: "t0"}))
    ->thenEvents([
      ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: P.Domain, at: "t0"}),
      ApiSchemaComputed({snapshot: [entry(~pluginId="p1", ~fragment=fragment1, ~apiTarget=P.Domain)]}),
    ])
  )

  test("re-registering an identical fragment + target is idempotent (no event)", () =>
    givenEvents([ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: P.Domain, at: "t0"})])
    ->whenCmd(RegisterApiFragment({pluginId: "p1", fragment: fragment1, apiTarget: P.Domain, at: "t1"}))
    ->thenNoEvent
  )

  test("registering a changed fragment emits ApiFragmentUpdated + ApiSchemaComputed", () =>
    givenEvents([ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: P.Domain, at: "t0"})])
    ->whenCmd(RegisterApiFragment({pluginId: "p1", fragment: fragment2, apiTarget: P.Domain, at: "t1"}))
    ->thenEvents([
      ApiFragmentUpdated({
        pluginId: "p1",
        previousFragment: fragment1,
        newFragment: fragment2,
        apiTarget: P.Domain,
        at: "t1",
      }),
      ApiSchemaComputed({snapshot: [entry(~pluginId="p1", ~fragment=fragment2, ~apiTarget=P.Domain)]}),
    ])
  )

  test("retargeting a plugin with an identical fragment emits ApiFragmentUpdated (fields move APIs)", () =>
    givenEvents([ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: P.Domain, at: "t0"})])
    ->whenCmd(RegisterApiFragment({pluginId: "p1", fragment: fragment1, apiTarget: P.Platform, at: "t1"}))
    ->thenEvents([
      ApiFragmentUpdated({
        pluginId: "p1",
        previousFragment: fragment1,
        newFragment: fragment1,
        apiTarget: P.Platform,
        at: "t1",
      }),
      ApiSchemaComputed({snapshot: [entry(~pluginId="p1", ~fragment=fragment1, ~apiTarget=P.Platform)]}),
    ])
  )

  test("registering a second plugin carries BOTH plugins in the snapshot (consistent whole-registry fold)", () =>
    givenEvents([ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: P.Domain, at: "t0"})])
    ->whenCmd(RegisterApiFragment({pluginId: "p2", fragment: fragment2, apiTarget: P.Platform, at: "t1"}))
    ->thenEvents([
      ApiFragmentRegistered({pluginId: "p2", fragment: fragment2, apiTarget: P.Platform, at: "t1"}),
      ApiSchemaComputed({
        snapshot: [
          entry(~pluginId="p1", ~fragment=fragment1, ~apiTarget=P.Domain),
          entry(~pluginId="p2", ~fragment=fragment2, ~apiTarget=P.Platform),
        ],
      }),
    ])
  )

  test("deregister emits ApiFragmentDeregistered + an empty-registry ApiSchemaComputed", () =>
    givenEvents([ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: P.Domain, at: "t0"})])
    ->whenCmd(DeregisterApiFragment({pluginId: "p1"}))
    ->thenEvents([ApiFragmentDeregistered({pluginId: "p1"}), ApiSchemaComputed({snapshot: []})])
  )

  test("deregistering an absent fragment is idempotent (no event)", () =>
    givenEvents([])->whenCmd(DeregisterApiFragment({pluginId: "p1"}))->thenNoEvent
  )

  test("recording a push outcome emits ONLY ApiFragmentPushRecorded (no snapshot, no recompute loop)", () =>
    givenEvents([ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: P.Domain, at: "t0"})])
    ->whenCmd(RecordApiFragmentPush({pluginId: "p1", ok: true, message: "", at: "t1"}))
    ->thenEvent(ApiFragmentPushRecorded({pluginId: "p1", ok: true, message: "", at: "t1"}))
  )

  test("redelivering an identical push record is idempotent (no event)", () =>
    givenEvents([
      ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: P.Domain, at: "t0"}),
      ApiFragmentPushRecorded({pluginId: "p1", ok: true, message: "", at: "t1"}),
    ])
    ->whenCmd(RecordApiFragmentPush({pluginId: "p1", ok: true, message: "", at: "t1"}))
    ->thenNoEvent
  )

  test("a later distinct push outcome is recorded again", () =>
    givenEvents([
      ApiFragmentRegistered({pluginId: "p1", fragment: fragment1, apiTarget: P.Domain, at: "t0"}),
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
