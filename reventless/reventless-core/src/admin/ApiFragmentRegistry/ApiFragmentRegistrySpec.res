// ApiFragmentRegistry aggregate — the platform API-schema fragment registry, replacing the
// raw `deploy-schema:*` keyspace (see docs/plans/event-sourced-fragment-registries.md).
//
// Modelled as a SINGLETON aggregate (fixed id, e.g. "registry"): the whole registry lives in
// one consistency boundary / one event stream, so a fragment change reads the whole registry
// with a single strongly-consistent partition read + snapshot — fixing the lagging-read
// consistency AND the unbounded-scan cost of the earlier per-plugin DCB-slice design (deploy
// validation #4). `pluginId` is a payload field here, not the aggregate id.
//
// Transitions are driven by the DEPLOY / DESTROY of a plugin stack: the deploy registers its
// fragment as a SigV4 system caller against the Platform API, and only final retirement
// (`pulumi destroy`, resolvers gone) deregisters. Version supersession must NOT deregister —
// the registry is keyed by plugin NAME, so a successor's deploy overwrites its predecessor's
// fragment in place. The registry is idempotent: re-registering an identical fragment is a
// no-op, deregistering an absent fragment is a no-op — it never rejects a command.
//
// `RecordApiFragmentPush` is the write-back of the reactive schema-push SideEffect: after
// stitching and pushing the composed schema it records the outcome (ok / error + message) on
// the row of the plugin whose fragment change triggered the push, so the deploy waiter can
// poll the push status instead of timing out on introspection. It is `@noApi` — dispatched
// platform-side, never by a GraphQL caller.
@@reventless.spec("ApiFragmentRegistry")

open Reventless.Plugin

// One entry of the consistent registry snapshot carried on `ApiSchemaComputed` — the whole
// per-plugin fragment set AFTER the triggering change, folded from the aggregate's own
// consistent state. The push SideEffect stitches per target from this snapshot (splitApi +
// admin base are its deploy concerns), so consistency is guaranteed without any
// eventually-consistent read.
@schema
type fragmentSnapshotEntry = {
  pluginId: string,
  encoded: string,
  protocol: string,
  apiTarget: apiTarget,
}

// `RegisterApiFragment` / `DeregisterApiFragment` ARE the GraphQL surface — the deploy calls
// them as a SigV4 system caller against the Platform API (exposed via the standard admin-aggregate
// path as `Platform_RegisterApiFragment` / `Platform_DeregisterApiFragment`; IAM via
// `systemCallerFieldNames`). `at` is the registration timestamp, threaded so the read-model row
// can surface registered/updated times.
@schema
type command =
  | RegisterApiFragment({pluginId: string, fragment: apiSchemaFragment, apiTarget: apiTarget, at: string})
  | DeregisterApiFragment({pluginId: string})
  | @noApi RecordApiFragmentPush({pluginId: string, ok: bool, message: string, at: string})

// The registry never rejects (idempotent register/deregister/record); this variant is never
// returned.
@schema
type error = | RegistryError

@schema
type event =
  | ApiFragmentRegistered({pluginId: string, fragment: apiSchemaFragment, apiTarget: apiTarget, at: string})
  | ApiFragmentUpdated({
      pluginId: string,
      previousFragment: apiSchemaFragment,
      newFragment: apiSchemaFragment,
      apiTarget: apiTarget,
      at: string,
    })
  | ApiFragmentDeregistered({pluginId: string})
  | ApiFragmentPushRecorded({pluginId: string, ok: bool, message: string, at: string})
  // Derived echo of the consistent registry contents after a fragment change — the reactive
  // push SideEffect's trigger. Carries the full per-plugin snapshot so the SideEffect stitches
  // from consistent state without a read. Does NOT change fold state (evolve ignores it), and
  // is NOT projected by the ApiFragments read model.
  | ApiSchemaComputed({snapshot: array<fragmentSnapshotEntry>})
