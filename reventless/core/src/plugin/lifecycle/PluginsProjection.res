open Reventless.Message

let moduleUrl: string = %raw(`import.meta.url`)

module Util = {
  let extractExtensionPointNames = Array.map(_, (
    extensionPoint: Reventless.Plugin.extensionPointDefinition,
  ) => extensionPoint.name)
  let extractExtensionNames = Array.map(_, (extension: Reventless.Plugin.extensionDefinition) =>
    extension.extensionPointName
  )

  let isConnected = (status: PluginsReadModelSpec.status) =>
    switch status {
    | Connected => true
    | Disconnected | Inactive | Retired => false
    }

  let without = (versions: array<Reventless.Plugin.version>, v) =>
    versions->Array.filter(x => x != v)
  let withVersion = (versions: array<Reventless.Plugin.version>, v) =>
    versions->Array.includes(v) ? versions : Array.concat(versions, [v])

  // Every version this row knows to be currently Connected — the `other` set
  // plus the row's own version when its status is Connected.
  let connectedVersions = (state: PluginsReadModelSpec.state): array<Reventless.Plugin.version> =>
    isConnected(state.status) ? state.otherConnectedVersions->withVersion(state.version) : state.otherConnectedVersions

  // Highest version (compareVersions) in the set, or None for an empty set.
  let highest = (versions: array<Reventless.Plugin.version>): option<Reventless.Plugin.version> =>
    versions->Array.reduce(None, (acc, v) =>
      switch acc {
      | None => Some(v)
      | Some(cur) => Plugin.compareVersions(v, cur) > 0 ? Some(v) : acc
      }
    )
}

// Build the flattened current-version row from a definition + status + the set
// of OTHER currently-connected versions (own version excluded).
let displayState = (
  def: Reventless.Plugin.pluginDefinition,
  status: PluginsReadModelSpec.status,
  statusChange,
  otherConnectedVersions,
): PluginsReadModelSpec.state => {
  let base: PluginsReadModelSpec.state = {
    name: def.name,
    version: def.version,
    eventCollector: def.eventCollector,
    extensionPoints: def.extensionPoints,
    extensionPointNames: def.extensionPoints->Util.extractExtensionPointNames,
    extensionNames: def.extensions->Util.extractExtensionNames,
    extensions: def.extensions,
    status,
    statusChange,
    // Store the offloadable fields as their untagged wire JSON (bare value, or an
    // `{$offload: {...}}` reference), not the `Offload.payload` variant: the QueryDb
    // write path marshals the raw ReScript value, so a variant would land in DynamoDB
    // as `{TAG, _0}`. The ComponentDefinitions Lambda then reads structure back and
    // resolves the sentinel.
    apiSchemaFragment: def.apiSchemaFragment->Option.map(
      Reventless.Offload.toJson(Reventless.Plugin.apiSchemaFragmentSchema, _),
    ),
    structure: def.structure->Option.map(
      Reventless.Offload.toJson(Reventless.Plugin.pluginStructureSchema, _),
    ),
    dcbEventLog: def.dcbEventLog,
    // A freshly projected row always knows its kind (the definition carries it as a
    // mandatory field). `option` here is purely for rows persisted before `kind`
    // existed — see PluginsReadModelSpec.state.kind.
    kind: Some(def.kind),
    // The current version is never listed among the "other" connected versions.
    otherConnectedVersions: otherConnectedVersions->Util.without(def.version),
  }
  switch def.apiTarget {
  | Some(target) => {...base, apiTarget: target}
  | None => base
  }
}

module PluginMapping = Reventless.Projection.Mapping.Make(
  PluginSpec,
  PluginsReadModelSpec,
  {
    let project = ({event, id, meta: {time, user: ?user}}) => {
      let statusChange = {at: time, by: user->Option.getOr("")}
      switch event {
      // Handshake trigger, supersession record and incompatibility
      // events do not change which version is current.
      | PluginSpec.VersionDetected(_)
      | VersionSuperseded(_)
      | IncompatiblePluginDetected(_) =>
        Reventless.Projection.Ignore

      // A version became live. It becomes current iff it is the highest
      // Connected version; otherwise the higher version stays current and this
      // one is recorded among the other currently-connected versions.
      | VersionConnected(def) | VersionActivated(def) =>
        Reventless.Projection.UpdateWithDefault(
          id,
          displayState(def, Connected, statusChange, []),
          state => {
            let connectedNow = Util.connectedVersions(state)->Util.withVersion(def.version)
            switch Util.highest(connectedNow) {
            | Some(hc) if hc == def.version =>
              displayState(def, Connected, statusChange, connectedNow)
            | _ => {
                ...state,
                otherConnectedVersions: state.otherConnectedVersions->Util.withVersion(def.version),
              }
            }
          },
        )

      // Rollback: this (possibly lower) version is explicitly promoted to current.
      // It leaves the "other" set (it is now the row's own version); the version
      // it replaces already left Connected (that is what triggered the promote).
      | VersionPromoted(def) =>
        Reventless.Projection.UpdateWithDefault(
          id,
          displayState(def, Connected, statusChange, []),
          state => displayState(def, Connected, statusChange, state.otherConnectedVersions),
        )

      // A version dropped out. The current row flips status; any OTHER version is
      // pruned from the connected set. A VersionPromoted (if any) follows and
      // overwrites the display with the rolled-back version.
      | VersionDisconnected(def) =>
        Reventless.Projection.UpdateWithDefault(
          id,
          displayState(def, Disconnected, statusChange, []),
          state =>
            state.version == def.version
              ? {...state, status: Disconnected, statusChange}
              : {...state, otherConnectedVersions: state.otherConnectedVersions->Util.without(def.version)},
        )
      | VersionDeactivated(def) =>
        Reventless.Projection.UpdateWithDefault(
          id,
          displayState(def, Inactive, statusChange, []),
          state =>
            state.version == def.version
              ? {...state, status: Inactive, statusChange}
              : {...state, otherConnectedVersions: state.otherConnectedVersions->Util.without(def.version)},
        )
      | VersionRetired(def) =>
        Reventless.Projection.UpdateWithDefault(
          id,
          displayState(def, Retired, statusChange, []),
          state =>
            state.version == def.version
              ? {...state, status: Retired, statusChange}
              : {...state, otherConnectedVersions: state.otherConnectedVersions->Util.without(def.version)},
        )
      }
    }
  },
)

module Mappings = Reventless.Projection.Mappings.Make(PluginsReadModelSpec)

let mappings: array<module(Mappings.Mapping)> = [module(PluginMapping)]
