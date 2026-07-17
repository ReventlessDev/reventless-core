// UiFragments StateViewSlice — the read side of the platform UI-fragment registry,
// replacing UIFragmentRegistryReadModelSpec + UIFragmentRegistryProjection. Projects the
// UiFragmentRegistry slice's events (from the shared admin DcbEventLog) into the
// manifest-per-plugin table that backs the Platform_UIFragments query. The wire shape is
// owned by Platform_UIFragmentsApi.res (SDL + encoder), pinned by the golden test
// Platform_UIFragmentsApiTest.res — `state` here matches that encoder byte-for-byte.
@@reventless.spec

open Reventless.Plugin

@schema
type state = {
  pluginId: string,
  remoteEntryUrl: string,
  panels: array<panelManifestEntry>,
  pages: array<pageManifestEntry>,
  registeredAt: string,
  updatedAt: string,
}

// Consumes the UiFragmentRegistry slice's events (from the shared admin DcbEventLog). Inline
// records with the same constructors/fields as the producer's `event` — decodes byte-identically
// and the ppx auto-tags `pluginId`.
@schema
type consumedEvent =
  | UiFragmentRegistered({pluginId: string, manifest: uiFragmentManifest, at: string})
  | UiFragmentUpdated({
      pluginId: string,
      previousManifest: uiFragmentManifest,
      newManifest: uiFragmentManifest,
      at: string,
    })
  | UiFragmentDeregistered({pluginId: string})
