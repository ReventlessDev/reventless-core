open Reventless.Message

let moduleUrl: string = %raw(`import.meta.url`)

module Util = {
  let extractExtensionPointNames = Array.map(_, (
    extensionPoint: Reventless.Plugin.extensionPointDefinition,
  ) => extensionPoint.name)
  let extractExtensionNames = Array.map(_, (extension: Reventless.Plugin.extensionDefinition) =>
    extension.extensionPointName
  )

  // Highest version (compareVersions) whose status string is "Connected".
  let highestConnected = (knownStatuses: dict<string>): option<string> =>
    knownStatuses
    ->Dict.toArray
    ->Array.reduce(None, (acc, (v, status)) =>
      if status == "Connected" {
        switch acc {
        | None => Some(v)
        | Some(cur) => Plugin.compareVersions(v, cur) > 0 ? Some(v) : acc
        }
      } else {
        acc
      }
    )
}

// Build the flattened current-version row from a definition + status + the
// updated knownStatuses map.
let displayState = (
  def: Reventless.Plugin.pluginDefinition,
  status: PluginsReadModelSpec.status,
  statusChange,
  knownStatuses,
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
    apiSchemaFragment: def.apiSchemaFragment,
    uiFragments: def.uiFragments,
    structure: def.structure,
    dcbEventLog: def.dcbEventLog,
    knownStatuses,
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
      let singleton = (v, status) => {
        let d = Dict.make()
        d->Dict.set(v, status)
        d
      }
      switch event {
      // Handshake trigger, supersession record, incompatibility and UI-fragment
      // events do not change which version is current.
      | PluginSpec.VersionDetected(_)
      | VersionSuperseded(_)
      | IncompatiblePluginDetected(_)
      | UIFragmentRegistered(_)
      | UIFragmentUpdated(_)
      | UIFragmentDeregistered(_) =>
        Reventless.Projection.Ignore

      // A version became live. It becomes current iff it is the highest
      // Connected version; otherwise just record its status (a higher version
      // stays current).
      | VersionConnected(def) | VersionActivated(def) =>
        Reventless.Projection.UpdateWithDefault(
          id,
          displayState(def, Connected, statusChange, singleton(def.version, "Connected")),
          state => {
            let known = state.knownStatuses->Dict.copy
            known->Dict.set(def.version, "Connected")
            switch Util.highestConnected(known) {
            | Some(hc) if hc == def.version => displayState(def, Connected, statusChange, known)
            | _ => {...state, knownStatuses: known}
            }
          },
        )

      // Rollback: this (possibly lower) version is explicitly promoted to current.
      | VersionPromoted(def) =>
        Reventless.Projection.UpdateWithDefault(
          id,
          displayState(def, Connected, statusChange, singleton(def.version, "Connected")),
          state => {
            let known = state.knownStatuses->Dict.copy
            known->Dict.set(def.version, "Connected")
            displayState(def, Connected, statusChange, known)
          },
        )

      // A version dropped out. Only touches the displayed status when the
      // dropped version IS the current row; a VersionPromoted (if any) follows
      // and overwrites the display with the rolled-back version.
      | VersionDisconnected(def) =>
        Reventless.Projection.UpdateWithDefault(
          id,
          displayState(def, Disconnected, statusChange, singleton(def.version, "Disconnected")),
          state => {
            let known = state.knownStatuses->Dict.copy
            known->Dict.set(def.version, "Disconnected")
            state.version == def.version
              ? {...state, status: Disconnected, statusChange, knownStatuses: known}
              : {...state, knownStatuses: known}
          },
        )
      | VersionDeactivated(def) =>
        Reventless.Projection.UpdateWithDefault(
          id,
          displayState(def, Inactive, statusChange, singleton(def.version, "Inactive")),
          state => {
            let known = state.knownStatuses->Dict.copy
            known->Dict.set(def.version, "Inactive")
            state.version == def.version
              ? {...state, status: Inactive, statusChange, knownStatuses: known}
              : {...state, knownStatuses: known}
          },
        )
      | VersionRetired(def) =>
        Reventless.Projection.UpdateWithDefault(
          id,
          displayState(def, Retired, statusChange, singleton(def.version, "Retired")),
          state => {
            let known = state.knownStatuses->Dict.copy
            known->Dict.set(def.version, "Retired")
            state.version == def.version
              ? {...state, status: Retired, statusChange, knownStatuses: known}
              : {...state, knownStatuses: known}
          },
        )
      }
    }
  },
)

module Mappings = Reventless.Projection.Mappings.Make(PluginsReadModelSpec)

let mappings: array<module(Mappings.Mapping)> = [module(PluginMapping)]
