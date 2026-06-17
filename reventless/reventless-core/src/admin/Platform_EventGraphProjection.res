open Reventless.Message
open Reventless.Projection

let moduleUrl: string = %raw(`import.meta.url`)

module EventGraphMapping = Reventless.Projection.Mapping.Make(
  PluginSpec,
  Platform_EventGraphReadModelSpec,
  {
    let project = ({event, id, meta: _}) =>
      // Keyed by plugin name. Reflects the structure of whichever version most
      // recently became current (connect / reactivate / rollback-promote). Drop-out
      // events are ignored rather than Delete: with name-keying a non-current
      // version timing out or being retired must not wipe the current version's
      // graph (a rollback re-Sets it via VersionPromoted).
      switch event {
      | PluginSpec.VersionConnected({name, structure: Some(structure)})
      | VersionActivated({name, structure: Some(structure)})
      | VersionPromoted({name, structure: Some(structure)}) =>
        Set(id, Platform_EventGraphReadModelSpec.buildEntry(~pluginName=name, structure))
      | VersionConnected({name, structure: None})
      | VersionActivated({name, structure: None})
      | VersionPromoted({name, structure: None}) =>
        Set(id, {Platform_EventGraphReadModelSpec.pluginName: name, nodes: [], edges: []})
      | VersionDetected(_)
      | VersionSuperseded(_)
      | VersionDisconnected(_)
      | VersionDeactivated(_)
      | VersionRetired(_)
      | IncompatiblePluginDetected(_)
      | UIFragmentRegistered(_)
      | UIFragmentUpdated(_)
      | UIFragmentDeregistered(_) => Ignore
      }
  },
)

module Mappings = Reventless.Projection.Mappings.Make(Platform_EventGraphReadModelSpec)

let mappings: array<module(Mappings.Mapping)> = [module(EventGraphMapping)]
