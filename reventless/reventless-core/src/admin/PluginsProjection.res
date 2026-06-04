open Reventless.Message

let moduleUrl: string = %raw(`import.meta.url`)

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
  PluginsReadModelSpec,
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
        let base: PluginsReadModelSpec.state = {
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
          dcbEventLog: pluginDef.dcbEventLog,
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
        let applyFragAndTarget = (s: PluginsReadModelSpec.state) => {
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
          dcbEventLog: pluginDef.dcbEventLog,
        })
        // dcbEventLog is immutable per plugin version — preserve whatever the
        // Connected event set and only refresh on Reconnected if the field
        // changed (a redeploy with new ARN).
        UpdateWithDefault(
          id,
          defaultState,
          state =>
            applyFragAndTarget({
              ...state,
              status: Connected,
              statusChange,
              dcbEventLog: switch pluginDef.dcbEventLog {
              | Some(_) as some => some
              | None => state.dcbEventLog
              },
            }),
        )
      | Disconnected({name, version, eventCollector, extensionPoints, extensions} as pluginDef)
      | Activated({name, version, eventCollector, extensionPoints, extensions} as pluginDef) =>
        UpdateWithDefault(
          id,
          {
            PluginsReadModelSpec.name,
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
            dcbEventLog: pluginDef.dcbEventLog,
          },
          state => {
            ...state,
            status: Disconnected,
            statusChange,
          },
        )
      | Deactivated({name, version, eventCollector, extensionPoints, extensions} as pluginDef) =>
        UpdateWithDefault(
          id,
          {
            PluginsReadModelSpec.name,
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
            dcbEventLog: pluginDef.dcbEventLog,
          },
          state => {
            ...state,
            status: Inactive,
            statusChange,
          },
        )
      | Retired({name, version, eventCollector, extensionPoints, extensions} as pluginDef) =>
        // Deploy-superseded version. Distinct status: Retired (vs Inactive for
        // admin Deactivate) — both are filtered from the manifest, but Retired
        // marks "obsoleted by a newer version", not "admin-suspended".
        UpdateWithDefault(
          id,
          {
            PluginsReadModelSpec.name,
            version,
            eventCollector,
            extensionPoints,
            extensionPointNames: extensionPoints->Util.extractExtensionPointNames,
            extensionNames: extensions->Util.extractExtensionNames,
            extensions,
            status: Retired,
            statusChange,
            apiSchemaFragment: None,
            uiFragments: None,
            structure: None,
            dcbEventLog: pluginDef.dcbEventLog,
          },
          state => {
            ...state,
            status: Retired,
            statusChange,
          },
        )
      }
    }
  },
)

module Mappings = Reventless.Projection.Mappings.Make(PluginsReadModelSpec)
//module type Mapping = Reventless.Projection.Mapping
//with type targetState := PluginsReadModelSpec.state

let mappings: array<module(Mappings.Mapping)> = [module(PluginMapping)]
