// UiFragmentRegistry StateChangeSlice — the write side of the platform UI-fragment
// registry, extracted off the Plugin aggregate (see
// docs/plans/event-sourced-fragment-registries.md).
//
// Commands are driven by the plugin runtime's connect handshake and routed here by the
// admin PluginExtensionPoint's UI-fragment mapping (RegisterUiFragment on ConnectPlugin,
// DeregisterUiFragment on DisconnectPlugin — the disconnect schedule sends DisconnectPlugin
// on heartbeat timeout too, so timeout deregistration flows through the same path).
//
// Keyed by plugin NAME (the `pluginId` tag carries the bare name), so a single row tracks
// the current manifest across version supersession. The registry is idempotent: re-sending
// an identical manifest is a no-op, deregistering an absent fragment is a no-op — it never
// rejects a command.
@@reventless.spec

open Reventless.Plugin

// `at` is the registration timestamp, stamped from the incoming command meta by the EP mapping
// — the StateViewSlice projection has no event meta, so time must ride the payload. Inline
// records let the ppx auto-tag `pluginId` (scoping the decision read to one plugin name).
//
// Whole-command `@noApi`: this registry has NO GraphQL surface — commands are driven by the
// plugin runtime's connect/disconnect handshake and routed here by the admin
// PluginExtensionPoint mapping (AWS) / direct admin-DCB dispatch (local), never by a mutation.
// Without this marker the DCB builder would emit orphaned `Platform_RegisterUiFragment`
// resolvers against a schema that never declares those fields.
@noApi @schema
type command =
  | RegisterUiFragment({pluginId: string, manifest: uiFragmentManifest, at: string})
  | DeregisterUiFragment({pluginId: string})

// The registry never rejects (idempotent register/deregister); this variant is never returned.
@schema
type error = | RegistryError

@schema
type event =
  | UiFragmentRegistered({pluginId: string, manifest: uiFragmentManifest, at: string})
  | UiFragmentUpdated({
      pluginId: string,
      previousManifest: uiFragmentManifest,
      newManifest: uiFragmentManifest,
      at: string,
    })
  | UiFragmentDeregistered({pluginId: string})

// This slice reads exactly the events it writes, so consumedEvent IS event — one inline event
// type, no duplicate-constructor collision, ppx auto-tags `pluginId` on both roles.
@schema
type consumedEvent = event
