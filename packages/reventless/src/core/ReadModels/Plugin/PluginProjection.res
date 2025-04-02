open ReventlessSpec.Message

module Util = {
  let extractExtensionPointNames = Array.map(_, (
    extensionPoint: ReventlessSpec.Plugin.extensionPointDefinition,
  ) => extensionPoint.name)
  let extractExtensionNames = Array.map(_, (extension: ReventlessSpec.Plugin.extensionDefinition) =>
    extension.extensionPointName
  )
}

module PluginMapping = Projection.Mapping.Make(
  PluginSpec,
  PluginReadModelSpec,
  {
    let map = ({event, id, meta: {time, user}}) => {
      let statusChange = {
        at: time,
        by: user,
      }
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
            statusChange,
          },
        )
      | Reconnected({name, version, eventCollector, extensionPoints, extensions}) =>
        UpdateWithDefault(
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
            statusChange,
          },
          state => {
            ...state,
            status: Connected,
            statusChange,
          },
        )
      | Disconnected({name, version, eventCollector, extensionPoints, extensions})
      | Activated({name, version, eventCollector, extensionPoints, extensions}) =>
        UpdateWithDefault(
          id,
          {
            PluginReadModelSpec.name,
            version,
            eventCollector,
            extensionPoints,
            extensionPointNames: extensionPoints->Util.extractExtensionPointNames,
            extensionNames: extensions->Util.extractExtensionNames,
            extensions,
            status: Disconnected,
            statusChange,
          },
          state => {
            ...state,
            status: Disconnected,
            statusChange,
          },
        )
      | Deactivated({name, version, eventCollector, extensionPoints, extensions}) =>
        UpdateWithDefault(
          id,
          {
            PluginReadModelSpec.name,
            version,
            eventCollector,
            extensionPoints,
            extensionPointNames: extensionPoints->Util.extractExtensionPointNames,
            extensionNames: extensions->Util.extractExtensionNames,
            extensions,
            status: Inactive,
            statusChange,
          },
          state => {
            ...state,
            status: Inactive,
            statusChange,
          },
        )
      }
    }
  },
)

module Mappings = Reventless.Projection.Mappings.Make(PluginReadModelSpec)
//module type Mapping = ReventlessSpec.Projection.Mapping
//with type targetState := PluginReadModelSpec.state

let mappings: array<module(Mappings.Mapping)> = [module(PluginMapping)]
