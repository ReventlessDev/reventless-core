open Reventless.Message
open Reventless.Projection

let moduleUrl: string = %raw(`import.meta.url`)

module Spec = PluginHistoryReadModelSpec

let transitionName = (t: Spec.transition): string =>
  switch t {
  | Detected => "Detected"
  | Connected => "Connected"
  | Superseded => "Superseded"
  | Promoted => "Promoted"
  | Disconnected => "Disconnected"
  | Activated => "Activated"
  | Deactivated => "Deactivated"
  | Retired => "Retired"
  | IncompatibleDetected => "IncompatibleDetected"
  }

// Build one timeline row. The transitionKey leads with the version (groups a
// version's transitions), then the producer time, then the transition kind to
// disambiguate same-version same-ms transitions.
let entry = (
  ~name,
  ~version,
  ~transition,
  ~transitionAt,
  ~by,
  ~supersededVersion=?,
): Spec.state => {
  let base: Spec.state = {
    name,
    version,
    transitionKey: `${version}#${transitionAt}#${transitionName(transition)}`,
    transition,
    transitionAt,
    by,
  }
  switch supersededVersion {
  | Some(sv) => {...base, supersededVersion: sv}
  | None => base
  }
}

module HistoryMapping = Reventless.Projection.Mapping.Make(
  PluginSpec,
  PluginHistoryReadModelSpec,
  {
    let project = ({event, id, meta: {time, user: ?user}}) => {
      let by = user->Option.getOr("")
      // Append one row per transition, keyed by the sort key (transitionKey).
      // UpdateMultiState is the composite-key collection action: it folds the
      // existing rows for this name and adds the new one (idempotent on
      // reprojection — a row with an already-present transitionKey is skipped).
      // `Set` would overwrite the whole partition.
      let row = (~version, ~transition, ~supersededVersion=?) => {
        let newRow = entry(
          ~name=id,
          ~version,
          ~transition,
          ~transitionAt=time,
          ~by,
          ~supersededVersion?,
        )
        UpdateMultiState(id, (rows: array<Spec.state>) =>
          rows->Array.some(r => r.transitionKey == newRow.transitionKey)
            ? rows
            : Array.concat(rows, [newRow])
        )
      }
      switch event {
      | PluginSpec.VersionDetected(v) => row(~version=v, ~transition=Detected)
      | VersionConnected(def) => row(~version=def.version, ~transition=Connected)
      | VersionSuperseded({supersededVersion, newVersion}) =>
        row(~version=newVersion, ~transition=Superseded, ~supersededVersion)
      | VersionPromoted(def) => row(~version=def.version, ~transition=Promoted)
      | VersionDisconnected(def) => row(~version=def.version, ~transition=Disconnected)
      | VersionActivated(def) => row(~version=def.version, ~transition=Activated)
      | VersionDeactivated(def) => row(~version=def.version, ~transition=Deactivated)
      | VersionRetired(def) => row(~version=def.version, ~transition=Retired)
      | IncompatiblePluginDetected(def) => row(~version=def.version, ~transition=IncompatibleDetected)
      // UI-fragment lifecycle is tracked by the UIFragmentRegistry, not the
      // version timeline.
      | UIFragmentRegistered(_)
      | UIFragmentUpdated(_)
      | UIFragmentDeregistered(_) =>
        Ignore
      }
    }
  },
)

module Mappings = Reventless.Projection.Mappings.Make(PluginHistoryReadModelSpec)

let mappings: array<module(Mappings.Mapping)> = [module(HistoryMapping)]
