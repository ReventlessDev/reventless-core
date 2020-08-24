open PluginSpec;

module Spec = PluginSpec;

[@decco]
type state =
  | Detected
  | Connected(plugin)
  | Disconnected(plugin)
  | Inactive(plugin);

let resolverConfig =
  Behaviour.{
    commandDecoder: command_decode,
    fields: [|"connectPlugin", "registerPlugin", "disconnectPlugin"|],
  };

let atomicCounter = None;

let create: Behaviour.create(command, event, error) =
  (. command, context, error, _) =>
    switch (command) {
    | Heartbeat => [UnknownPluginDetected]
    | ConnectPlugin(_)
    | DisconnectPlugin
    | ActivatePlugin
    | DeactivatePlugin =>
      error(PluginDoesNotExist, command, context);
      [];
    };

let execute: Behaviour.execute(state, command, event, error) =
  (. _, command, _, _, _) => {
    switch (command) {
    | Heartbeat => []
    | ConnectPlugin(plugin) => [PluginConnected(plugin)]
    | DisconnectPlugin => [PluginDisconnected]
    | ActivatePlugin => [PluginActivated]
    | DeactivatePlugin => [PluginDeactivated]
    };
  };

let init: Behaviour.init(state, event) =
  (. event) =>
    switch (event) {
    | UnknownPluginDetected => Detected
    | PluginConnected(plugin) => Connected(plugin)
    | PluginDisconnected
    | PluginActivated
    | PluginDeactivated =>
      raise(Reventless.Message.InvalidEvent(event_encode(event)))
    };

let apply: Behaviour.apply(state, event) =
  (. state: state, event) => {
    switch (event) {
    | UnknownPluginDetected =>
      raise(Reventless.Message.InvalidEvent(event_encode(event)))
    | PluginConnected(plugin) => Connected(plugin)
    | PluginDisconnected
    | PluginActivated =>
      let plugin =
        switch (state) {
        | Detected
        | Disconnected(_) =>
          raise(
            Reventless.Message.InvalidEvent(PluginSpec.event_encode(event)),
          )
        | Connected(plugin)
        | Inactive(plugin) => plugin
        };
      Disconnected(plugin);
    | PluginDeactivated =>
      let plugin =
        switch (state) {
        | Detected
        | Disconnected(_)
        | Inactive(_) =>
          raise(
            Reventless.Message.InvalidEvent(PluginSpec.event_encode(event)),
          )
        | Connected(plugin) => plugin
        };
      Inactive(plugin);
    };
  };
