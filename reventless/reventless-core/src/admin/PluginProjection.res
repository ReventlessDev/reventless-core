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
    let project = ({event, id, meta: {time, user: ?user}}) => {
      let statusChange = {
        at: time,
        by: user->Option.getOr(""),
      }
      switch event {
      | PluginSpec.UnknownPluginDetected
      | IncompatiblePluginDetected(_)
      | UIFragmentRegistered(_)
      | UIFragmentUpdated(_)
      | UIFragmentDeregistered(_) => Reventless.Projection.Ignore
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
          uiFragments: None,
          structure: None,
        }
        let withFrag = switch pluginDef.apiSchemaFragment {
        | Some(frag) => {...base, apiSchemaFragment: Some(frag)}
        | None => base
        }
        let withUi = switch pluginDef.uiFragments {
        | Some(ui) => {...withFrag, uiFragments: Some(ui)}
        | None => withFrag
        }
        let withStructure = switch pluginDef.structure {
        | Some(s) => {...withUi, structure: Some(s)}
        | None => withUi
        }
        let state = switch pluginDef.apiTarget {
        | Some(target) => {...withStructure, apiTarget: target}
        | None => withStructure
        }
        Set(id, state)
      | Reconnected({name, version, eventCollector, extensionPoints, extensions} as pluginDef) =>
        let applyFragAndTarget = (s: PluginReadModelSpec.state) => {
          let withFrag = switch pluginDef.apiSchemaFragment {
          | Some(frag) => {...s, apiSchemaFragment: Some(frag)}
          | None => s
          }
          let withUi = switch pluginDef.uiFragments {
          | Some(ui) => {...withFrag, uiFragments: Some(ui)}
          | None => withFrag
          }
          let withStructure = switch pluginDef.structure {
          | Some(struct) => {...withUi, structure: Some(struct)}
          | None => withUi
          }
          switch pluginDef.apiTarget {
          | Some(target) => {...withStructure, apiTarget: target}
          | None => withStructure
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
          uiFragments: None,
          structure: None,
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
            uiFragments: None,
            structure: None,
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
            uiFragments: None,
            structure: None,
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
