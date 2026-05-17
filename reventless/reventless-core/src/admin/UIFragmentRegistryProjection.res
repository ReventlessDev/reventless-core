open Reventless.Message
open Reventless.Projection

let moduleUrl: string = %raw(`import.meta.url`)

module UIFragmentRegistryMapping = Reventless.Projection.Mapping.Make(
  PluginSpec,
  UIFragmentRegistryReadModelSpec,
  {
    let project = ({event, id, meta: {time}}) =>
      switch event {
      | PluginSpec.UIFragmentRegistered({manifest}) =>
        Set(
          id,
          {
            UIFragmentRegistryReadModelSpec.pluginId: id,
            remoteEntryUrl: manifest.remoteEntryUrl,
            panels: manifest.panels,
            pages: manifest.pages,
            registeredAt: time,
            updatedAt: time,
          },
        )
      | UIFragmentUpdated({newManifest}) =>
        Update(
          id,
          state => {
            ...state,
            remoteEntryUrl: newManifest.remoteEntryUrl,
            panels: newManifest.panels,
            pages: newManifest.pages,
            updatedAt: time,
          },
        )
      | UIFragmentDeregistered(_) => Delete(id)
      | _ => Ignore
      }
  },
)

module Mappings = Reventless.Projection.Mappings.Make(UIFragmentRegistryReadModelSpec)

let mappings: array<module(Mappings.Mapping)> = [module(UIFragmentRegistryMapping)]
