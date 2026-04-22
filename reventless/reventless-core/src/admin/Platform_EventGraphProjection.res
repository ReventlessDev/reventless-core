open Reventless.Message
open Reventless.Projection

module EventGraphMapping = Reventless.Projection.Mapping.Make(
  PluginSpec,
  Platform_EventGraphReadModelSpec,
  {
    let project = ({event, id, meta: _}) =>
      switch event {
      | PluginSpec.Connected({name, structure: Some(structure)})
      | Reconnected({name, structure: Some(structure)})
      | Activated({name, structure: Some(structure)}) =>
        Set(id, Platform_EventGraphReadModelSpec.buildEntry(~pluginName=name, structure))
      | Connected({name, structure: None})
      | Reconnected({name, structure: None})
      | Activated({name, structure: None}) =>
        Set(id, {Platform_EventGraphReadModelSpec.pluginName: name, nodes: [], edges: []})
      | Disconnected(_) | Deactivated(_) => Delete(id)
      | UnknownPluginDetected
      | IncompatiblePluginDetected(_)
      | UIFragmentRegistered(_)
      | UIFragmentUpdated(_)
      | UIFragmentDeregistered(_) => Ignore
      }
  },
)

module Mappings = Reventless.Projection.Mappings.Make(Platform_EventGraphReadModelSpec)

let mappings: array<module(Mappings.Mapping)> = [module(EventGraphMapping)]
