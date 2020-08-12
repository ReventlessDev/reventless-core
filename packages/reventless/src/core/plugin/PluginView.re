open Reventless.View;
open PluginSpec;

[@decco]
type status =
  | Detected
  | Connected
  | Disconnected
  | Inactive;

[@decco]
type state = {
  name,
  version,
  dependencies,
  status,
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
    | UnknownPluginDetected
    | PluginConnected(_)
    | PluginDisconnected
    | PluginActivated
    | PluginDeactivated => []
    };

let applyMulti =
  (. states, event, context) =>
    states
    |> List.map(state => apply(. state, event, context))
    |> List.flatten;
