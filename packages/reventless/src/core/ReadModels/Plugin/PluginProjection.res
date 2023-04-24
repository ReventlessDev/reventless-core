open ReventlessSpec.Message

module Util = {
  let extractExtensionPointNames = Belt.Array.map(_, (
    extensionPoint: ReventlessSpec.Plugin.extensionPointDefinition,
  ) => extensionPoint.name)
  let extractExtensionNames = Belt.Array.map(_, (extension: ReventlessSpec.Plugin.extensionDefinition) =>
    extension.extensionPointName
  )
}

module PluginMapping = Projection.Mapping.Make(PluginSpec, PluginReadModelSpec, {
  //module Source = PluginSpec
  //module Target = PluginReadModelSpec

  let map = ({event, id, meta: {time, user}}) =>
    switch event {
    | PluginSpec.UnknownPluginDetected => ReventlessSpec.Projection.Spec.Ignore
    | Connected({name, version, eventCollector, extensionPoints, extensions}) =>
      Set(
        id,
        {
          PluginReadModelSpec.name,
          version,
          eventCollector,
          extensionPoints,
          extensionPointNames: extensionPoints->Util.extractExtensionPointNames,
          extensionNames: extensions->Util.extractExtensionNames,
          extensions,
          status: Connected,
          statusChange: {
            at: time,
            by: user,
          },
        },
      )
    | Reconnected(_) =>
      Update(
        id,
        state => {
          ...state,
          status: Connected,
          statusChange: {
            at: time,
            by: user,
          },
        },
      )
    | Disconnected(_)
    | Activated(_) =>
      Update(
        id,
        state => {
          ...state,
          status: Disconnected,
          statusChange: {
            at: time,
            by: user,
          },
        },
      )
    | Deactivated(_) =>
      Update(
        id,
        state => {
          ...state,
          status: Inactive,
          statusChange: {
            at: time,
            by: user,
          },
        },
      )
    }
})

module Mappings = Reventless.Projection.Mappings.Make(PluginReadModelSpec)
//module type Mapping = ReventlessSpec.Projection.Mapping
  //with type targetState := PluginReadModelSpec.state

let mappings: array<module(Mappings.Mapping)> = [module(PluginMapping)]
