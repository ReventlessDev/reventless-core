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
  extensionPoints: array(extensionPointDefinition),
  extensionPointNames: array(string),
  extensions: array(extensionDefinition),
  status,
  statusChange: Message.statusChange,
};

let name = None;

let resolveIdConfigs = [];
let resolveIdsConfigs = [];

let sortConfig = None;

let indexes = [];

let extractNames =
  Belt.Array.map(_, (extensionPoint: extensionPointDefinition) =>
    extensionPoint.name
  );

let init =
  (. event, {Message.meta: {time, user}}) =>
    switch (event) {
    | UnknownPluginDetected => []
    | PluginConnected({name, version, extensionPoints, extensions}) => [
        {
          name,
          version,
          extensionPoints,
          extensionPointNames: extensionPoints->extractNames,
          extensions,
          status: Connected,
          statusChange: {
            at: time,
            by: user,
          },
        },
      ]
    | PluginReconnected(_)
    | PluginDisconnected(_)
    | PluginActivated(_)
    | PluginDeactivated(_) =>
      raise(Reventless.Message.InvalidEvent(PluginSpec.event_encode(event)))
    };

let apply =
  (. state, event, {Message.meta: {time, user}}) =>
    switch (event) {
    | UnknownPluginDetected => []
    | PluginConnected({name, version, extensionPoints, extensions}) => [
        Update({
          name,
          version,
          extensionPoints,
          extensionPointNames: extensionPoints->extractNames,
          extensions,
          status: Connected,
          statusChange: {
            at: time,
            by: user,
          },
        }),
      ]
    | PluginReconnected(_) => [
        Update({
          ...state,
          status: Connected,
          statusChange: {
            at: time,
            by: user,
          },
        }),
      ]
    | PluginDisconnected(_)
    | PluginActivated(_) => [
        Update({
          ...state,
          status: Disconnected,
          statusChange: {
            at: time,
            by: user,
          },
        }),
      ]
    | PluginDeactivated(_) => [
        Update({
          ...state,
          status: Inactive,
          statusChange: {
            at: time,
            by: user,
          },
        }),
      ]
    };

let applyMulti =
  (. states, event, context) =>
    states
    ->Belt.List.map(state => apply(. state, event, context))
    ->Belt.List.flatten;
