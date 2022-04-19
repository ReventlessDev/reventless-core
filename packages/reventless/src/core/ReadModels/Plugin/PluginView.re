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
  eventCollector: string,
  extensionPoints: array(extensionPointDefinition),
  extensionPointNames: array(string),
  extensionNames: array(string),
  extensions: array(extensionDefinition),
  status,
  statusChange: Message.statusChange,
};

type queryResult = {
  id: string,
  name,
  version,
  eventCollector: string,
  extensionPoints: array(extensionPointDefinition),
  extensionPointNames: array(string),
  extensionNames: array(string),
  extensions: array(extensionDefinition),
  status,
};

let name = None;

let resolveIdConfigs = [];
let resolveIdsConfigs = [];

let sortConfig = None;

let indexes = [];

let extractExtensionPointNames =
  Belt.Array.map(_, (extensionPoint: extensionPointDefinition) =>
    extensionPoint.name
  );
let extractExtensionNames =
  Belt.Array.map(_, (extension: extensionDefinition) =>
    extension.extensionPointName
  );

let init =
  (. event, {Message.meta: {time, user}}) =>
    switch (event) {
    | UnknownPluginDetected => []
    | Connected({name, version, eventCollector, extensionPoints, extensions}) => [
        {
          name,
          version,
          eventCollector,
          extensionPoints,
          extensionPointNames: extensionPoints->extractExtensionPointNames,
          extensionNames: extensions->extractExtensionNames,
          extensions,
          status: Connected,
          statusChange: {
            at: time,
            by: user,
          },
        },
      ]
    | Reconnected(_)
    | Disconnected(_)
    | Activated(_)
    | Deactivated(_) =>
      raise(Reventless.Message.InvalidEvent(PluginSpec.event_encode(event)))
    };

let apply =
  (. state, event, {Message.meta: {time, user}}) =>
    switch (event) {
    | UnknownPluginDetected => []
    | Connected({name, version, eventCollector, extensionPoints, extensions}) => [
        Update({
          name,
          version,
          eventCollector,
          extensionPoints,
          extensionPointNames: extensionPoints->extractExtensionPointNames,
          extensionNames: extensions->extractExtensionNames,
          extensions,
          status: Connected,
          statusChange: {
            at: time,
            by: user,
          },
        }),
      ]
    | Reconnected(_) => [
        Update({
          ...state,
          status: Connected,
          statusChange: {
            at: time,
            by: user,
          },
        }),
      ]
    | Disconnected(_)
    | Activated(_) => [
        Update({
          ...state,
          status: Disconnected,
          statusChange: {
            at: time,
            by: user,
          },
        }),
      ]
    | Deactivated(_) => [
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
