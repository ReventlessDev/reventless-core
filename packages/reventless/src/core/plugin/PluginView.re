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
  extensionPoints,
  extensions,
  status,
  since: string,
};

let name = None;

let resolveIdConfigs = [];
let resolveIdsConfigs = [];

let sortConfig = None;

let indexes = [];

let init =
  (. event, context: Message.context) =>
    switch (event) {
    | UnknownPluginDetected => []
    | PluginConnected({name, version, extensionPoints, extensions}) => [
        {
          name,
          version,
          extensionPoints,
          extensions,
          status: Connected,
          since: context.meta.time,
        },
      ]
    | PluginReconnected
    | PluginDisconnected
    | PluginActivated
    | PluginDeactivated =>
      raise(Reventless.Message.InvalidEvent(PluginSpec.event_encode(event)))
    };

let apply =
  (. state, event, context: Message.context) =>
    switch (event) {
    | UnknownPluginDetected => []
    | PluginConnected({name, version, extensionPoints, extensions}) => [
        Update({
          name,
          version,
          extensionPoints,
          extensions,
          status: Connected,
          since: context.meta.time,
        }),
      ]
    | PluginReconnected => [
        Update({...state, status: Connected, since: context.meta.time}),
      ]
    | PluginDisconnected
    | PluginActivated => [
        Update({...state, status: Disconnected, since: context.meta.time}),
      ]
    | PluginDeactivated => [
        Update({...state, status: Inactive, since: context.meta.time}),
      ]
    };

let applyMulti =
  (. states, event, context) =>
    states
    |> List.map(state => apply(. state, event, context))
    |> List.flatten;
