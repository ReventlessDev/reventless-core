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
    fields: [|"activatePlugin", "deactivatePlugin"|],
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
  (. state, command, _, _, _) => {
    switch (state) {
    | Detected =>
      switch (command) {
      | ConnectPlugin(plugin) => [PluginConnected(plugin)]
      | Heartbeat
      | DisconnectPlugin
      | ActivatePlugin
      | DeactivatePlugin => []
      }
    | Connected(_) =>
      switch (command) {
      | DisconnectPlugin => [PluginDisconnected]
      | DeactivatePlugin => [PluginDeactivated]
      | Heartbeat
      | ConnectPlugin(_)
      | ActivatePlugin => []
      }
    | Disconnected(_) =>
      switch (command) {
      | Heartbeat => [PluginReconnected]
      | DeactivatePlugin => [PluginDeactivated]
      | ConnectPlugin(_)
      | DisconnectPlugin
      | ActivatePlugin => []
      }
    | Inactive(_) =>
      switch (command) {
      | ActivatePlugin => [PluginActivated]
      | Heartbeat
      | ConnectPlugin(_)
      | DisconnectPlugin
      | DeactivatePlugin => []
      }
    };
  };

let init: Behaviour.init(state, event) =
  (. event) =>
    switch (event) {
    | UnknownPluginDetected => Detected
    | PluginConnected(_)
    | PluginReconnected
    | PluginDisconnected
    | PluginActivated
    | PluginDeactivated =>
      raise(Reventless.Message.InvalidEvent(event_encode(event)))
    };

let apply: Behaviour.apply(state, event) =
  (. state: state, event) => {
    switch (state) {
    | Detected =>
      switch (event) {
      | PluginConnected(plugin) => Connected(plugin)
      | UnknownPluginDetected
      | PluginReconnected
      | PluginDisconnected
      | PluginActivated
      | PluginDeactivated =>
        raise(Reventless.Message.InvalidEvent(event_encode(event)))
      }
    | Connected(plugin) =>
      switch (event) {
      | PluginDisconnected => Disconnected(plugin)
      | PluginDeactivated => Inactive(plugin)
      | UnknownPluginDetected
      | PluginConnected(_)
      | PluginReconnected
      | PluginActivated =>
        raise(Reventless.Message.InvalidEvent(event_encode(event)))
      }
    | Disconnected(plugin) =>
      switch (event) {
      | PluginReconnected => Connected(plugin)
      | PluginDeactivated => Inactive(plugin)
      | UnknownPluginDetected
      | PluginConnected(_)
      | PluginDisconnected
      | PluginActivated =>
        raise(Reventless.Message.InvalidEvent(event_encode(event)))
      }
    | Inactive(plugin) =>
      switch (event) {
      | PluginActivated => Disconnected(plugin)
      | UnknownPluginDetected
      | PluginConnected(_)
      | PluginReconnected
      | PluginDisconnected
      | PluginDeactivated =>
        raise(Reventless.Message.InvalidEvent(event_encode(event)))
      }
    };
  };
