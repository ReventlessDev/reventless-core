open Reventless.Message

module Util = {
  let extractExtensionPointNames = Array.map(_, (
    extensionPoint: Reventless.Plugin.extensionPointDefinition,
  ) => extensionPoint.name)
  let extractExtensionNames = Array.map(_, (extension: Reventless.Plugin.extensionDefinition) =>
    extension.extensionPointName
  )
}

module PluginMapping = Reventless.Projection.Mapping.Make(
  PluginSpec,
  PluginReadModelSpec,
  {
    let project = ({event, id, meta: {time, user}}) => {
      let statusChange = {
        at: time,
        by: user,
      }
      switch event {
      | PluginSpec.UnknownPluginDetected
      | IncompatiblePluginDetected(_) => Reventless.Projection.Ignore
      | Connected({name, version, eventCollector, extensionPoints, extensions} as pluginDef) =>
        let base: PluginReadModelSpec.state = {
          name,
          version,
          eventCollector,
          extensionPoints,
          extensionPointNames: extensionPoints->Util.extractExtensionPointNames,
          extensionNames: extensions->Util.extractExtensionNames,
          extensions,
          status: Connected,
          statusChange,
          apiSchemaFragment: None,
        }
        let withFrag = switch pluginDef.apiSchemaFragment {
        | Some(frag) => {...base, apiSchemaFragment: Some(frag)}
        | None => base
        }
        let state = switch pluginDef.apiTarget {
        | Some(target) => {...withFrag, apiTarget: target}
        | None => withFrag
        }
        Set(id, state)
      | Reconnected({name, version, eventCollector, extensionPoints, extensions} as pluginDef) =>
        let applyFragAndTarget = (s: PluginReadModelSpec.state) => {
          let withFrag = switch pluginDef.apiSchemaFragment {
          | Some(frag) => {...s, apiSchemaFragment: Some(frag)}
          | None => s
          }
          switch pluginDef.apiTarget {
          | Some(target) => {...withFrag, apiTarget: target}
          | None => withFrag
          }
        }
        let defaultState = applyFragAndTarget({
          name,
          version,
          eventCollector,
          extensionPoints,
          extensionPointNames: extensionPoints->Util.extractExtensionPointNames,
          extensionNames: extensions->Util.extractExtensionNames,
          extensions,
          status: Connected,
          statusChange,
          apiSchemaFragment: None,
        })
        UpdateWithDefault(
          id,
          defaultState,
          state => applyFragAndTarget({...state, status: Connected, statusChange}),
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
            apiSchemaFragment: None,
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
            apiSchemaFragment: None,
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
//module type Mapping = Reventless.Projection.Mapping
//with type targetState := PluginReadModelSpec.state

let mappings: array<module(Mappings.Mapping)> = [module(PluginMapping)]
