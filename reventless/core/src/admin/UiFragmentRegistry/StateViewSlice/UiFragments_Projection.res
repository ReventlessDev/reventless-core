@@reventless.projection

// No `open Reventless.Plugin`: it would shadow the state labels (panels/pages/...) brought in
// by the projection's spec open. `manifest.<field>` resolves type-directed from the event's
// uiFragmentManifest payload.
let project = event =>
  switch event {
  | UiFragmentRegistered({pluginId, manifest, at}) => [
      Set(
        pluginId,
        {
          pluginId,
          remoteEntryUrl: manifest.remoteEntryUrl,
          panels: manifest.panels,
          pages: manifest.pages,
          registeredAt: at,
          updatedAt: at,
        },
      ),
    ]
  | UiFragmentUpdated({pluginId, newManifest, at}) => [
      Update(
        pluginId,
        state => {
          ...state,
          remoteEntryUrl: newManifest.remoteEntryUrl,
          panels: newManifest.panels,
          pages: newManifest.pages,
          updatedAt: at,
        },
      ),
    ]
  | UiFragmentDeregistered({pluginId}) => [Delete(pluginId)]
  }
