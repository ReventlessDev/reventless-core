open Reventless.View;
open PluginSpec;

[@decco]
type status =
  | Connected
  | Disconnected
  | Inactive;

[@decco]
type state = {
  name,
  version,
  status,
  extensionPoints,
  extensions,
};

let name = None;

let resolveIdConfigs = [];
let resolveIdsConfigs = [];

let sortConfig = None;

let indexes = [];

let init: init(state, event) =
  (. event, _) =>
    switch (event) {
    | UnknownPluginDetected => []
    | PluginConnected(_)
    | PluginDisconnected
    | PluginActivated
    | PluginDeactivated =>
      raise(Reventless.Message.InvalidEvent(PluginSpec.event_encode(event)))
    };

let apply: apply(state, event) =
  (. state, event, _) =>
    switch (event) {
    | UnknownPluginDetected => []
    | PluginConnected({name, version, extensionPoints, extensions}) => [
        Create({
          name,
          version,
          status: Connected,
          extensionPoints,
          extensions,
        }),
      ]
    | PluginDisconnected
    | PluginActivated => [
        Update({
          name: state.name,
          version: state.version,
          status: Disconnected,
          extensionPoints: state.extensionPoints,
          extensions: state.extensions,
        }),
      ]
    | PluginDeactivated => [
        Update({
          name: state.name,
          version: state.version,
          status: Inactive,
          extensionPoints: state.extensionPoints,
          extensions: state.extensions,
        }),
      ]
    };

let applyMulti =
  (. states, event, context) =>
    states
    |> List.map(state => apply(. state, event, context))
    |> List.flatten;
