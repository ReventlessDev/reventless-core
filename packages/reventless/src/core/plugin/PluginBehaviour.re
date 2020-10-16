open PluginSpec;

module Spec = PluginSpec;

[@decco]
type state =
  | Detected
  | Connected(pluginDefinition)
  | Disconnected(pluginDefinition)
  | Inactive(pluginDefinition);

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
      | ConnectPlugin(pluginDefinition) => [
          PluginConnected(pluginDefinition),
        ]
      | Heartbeat
      | DisconnectPlugin
      | ActivatePlugin
      | DeactivatePlugin => []
      }
    | Connected(pluginDefinition) =>
      switch (command) {
      | DisconnectPlugin => [PluginDisconnected(pluginDefinition)]
      | DeactivatePlugin => [PluginDeactivated(pluginDefinition)]
      | Heartbeat
      | ConnectPlugin(_)
      | ActivatePlugin => []
      }
    | Disconnected(pluginDefinition) =>
      switch (command) {
      | Heartbeat => [PluginReconnected(pluginDefinition)]
      | DeactivatePlugin => [PluginDeactivated(pluginDefinition)]
      | ConnectPlugin(_)
      | DisconnectPlugin
      | ActivatePlugin => []
      }
    | Inactive(pluginDefinition) =>
      switch (command) {
      | ActivatePlugin => [PluginActivated(pluginDefinition)]
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
    | PluginReconnected(_)
    | PluginDisconnected(_)
    | PluginActivated(_)
    | PluginDeactivated(_) =>
      raise(Reventless.Message.InvalidEvent(event_encode(event)))
    };

let apply: Behaviour.apply(state, event) =
  (. state: state, event) => {
    switch (state) {
    | Detected =>
      switch (event) {
      | PluginConnected(pluginDefinition) => Connected(pluginDefinition)
      | UnknownPluginDetected
      | PluginReconnected(_)
      | PluginDisconnected(_)
      | PluginActivated(_)
      | PluginDeactivated(_) =>
        raise(Reventless.Message.InvalidEvent(event_encode(event)))
      }
    | Connected(pluginDefinition) =>
      switch (event) {
      | PluginDisconnected(_) => Disconnected(pluginDefinition)
      | PluginDeactivated(_) => Inactive(pluginDefinition)
      | UnknownPluginDetected
      | PluginConnected(_)
      | PluginReconnected(_)
      | PluginActivated(_) =>
        raise(Reventless.Message.InvalidEvent(event_encode(event)))
      }
    | Disconnected(pluginDefinition) =>
      switch (event) {
      | PluginReconnected(_) => Connected(pluginDefinition)
      | PluginDeactivated(_) => Inactive(pluginDefinition)
      | UnknownPluginDetected
      | PluginConnected(_)
      | PluginDisconnected(_)
      | PluginActivated(_) =>
        raise(Reventless.Message.InvalidEvent(event_encode(event)))
      }
    | Inactive(pluginDefinition) =>
      switch (event) {
      | PluginActivated(_) => Disconnected(pluginDefinition)
      | UnknownPluginDetected
      | PluginConnected(_)
      | PluginReconnected(_)
      | PluginDisconnected(_)
      | PluginDeactivated(_) =>
        raise(Reventless.Message.InvalidEvent(event_encode(event)))
      }
    };
  };
