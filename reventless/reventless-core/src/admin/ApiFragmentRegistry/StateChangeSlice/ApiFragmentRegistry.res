// ApiFragmentRegistry StateChangeSlice — the write side of the platform API-schema
// fragment registry, replacing the raw `deploy-schema:*` keyspace (see
// docs/plans/event-sourced-fragment-registries.md).
//
// Unlike the UiFragmentRegistry (connect/disconnect-driven), this registry's transitions
// are driven by the DEPLOY / DESTROY of a plugin stack: the deploy registers its fragment
// as a SigV4 system caller against the Platform API, and only final retirement
// (`pulumi destroy`, resolvers gone) deregisters. Version supersession must NOT
// deregister — the registry is keyed by plugin NAME, so a successor's deploy overwrites
// its predecessor's fragment in place.
//
// The registry is idempotent: re-registering an identical fragment is a no-op,
// deregistering an absent fragment is a no-op — it never rejects a command.
//
// `RecordApiFragmentPush` is the write-back of the single-writer schema-push automation:
// after stitching and pushing the composed schema it records the outcome (ok / error +
// message) on the row of the plugin whose fragment change triggered the push, so a
// deploy waiter can poll the push status instead of timing out on introspection.
@@reventless.spec

open Reventless.Plugin

// `at` is the registration timestamp, stamped from the incoming command meta by the
// dispatching mapping — the StateViewSlice projection has no event meta, so time must
// ride the payload. Inline records let the ppx auto-tag `pluginId` (scoping the decision
// read to one plugin name). `message` is a plain string ("" = none) — option fields in
// variant payloads don't survive the T|null wire contract cleanly.
//
// `apiTarget` is the API this plugin's fields belong to — Domain (the default) or Platform.
// A plugin assigned to the Platform API (e.g. a platform inspector) stitches into the
// Platform-API schema, not the Domain-API one; the single-writer push automation groups
// fragments by this target and maintains one cumulative schema per API.
// `RegisterApiFragment` / `DeregisterApiFragment` ARE the GraphQL surface — the deploy calls them
// as a SigV4 system caller against the Platform API (exposed as `Platform_RegisterApiFragment` /
// `Platform_DeregisterApiFragment`). `RecordApiFragmentPush` is `@noApi`: it is the internal
// write-back of the single-writer schema-push automation, dispatched platform-side, never by a
// GraphQL caller.
@schema
type command =
  | RegisterApiFragment({pluginId: string, fragment: apiSchemaFragment, apiTarget: apiTarget, at: string})
  | DeregisterApiFragment({pluginId: string})
  | @noApi RecordApiFragmentPush({pluginId: string, ok: bool, message: string, at: string})

// The registry never rejects (idempotent register/deregister/record); this variant is
// never returned.
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

// This slice reads exactly the events it writes, so consumedEvent IS event — one inline
// event type, no duplicate-constructor collision, ppx auto-tags `pluginId` on both roles.
@schema
type consumedEvent = event
