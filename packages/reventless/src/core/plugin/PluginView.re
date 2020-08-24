open View;
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
    | PluginConnected({name, version, extensionPoints, extensions}) => [
        {name, version, extensionPoints, extensions, status: Connected},
      ]
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
        Update({
          name,
          version,
          extensionPoints,
          extensions,
          status: Connected,
        }),
      ]
    | PluginDisconnected
    | PluginActivated => [Update({...state, status: Disconnected})]
    | PluginDeactivated => [Update({...state, status: Inactive})]
    };

let applyMulti =
  (. states, event, context) =>
    states
    |> List.map(state => apply(. state, event, context))
    |> List.flatten;
