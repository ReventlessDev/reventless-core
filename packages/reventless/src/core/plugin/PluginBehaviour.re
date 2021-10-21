open PluginSpec;

module Spec = PluginSpec;

[@decco]
type state =
  | Detected
  | Connected(pluginDefinition, array(apiFragmentDescription))
  | Disconnected(pluginDefinition, array(apiFragmentDescription))
  | Inactive(pluginDefinition, array(apiFragmentDescription));

let resolverConfig =
  Behaviour.{
    commandDecoder: command_decode,
    fields: [|"activatePlugin", "deactivatePlugin"|],
  };

let atomicCounter = None;

let create: Behaviour.create(command, event, error) =
  (. command, context, error) =>
    switch (command) {
    | Heartbeat => [UnknownPluginDetected]
    | ConnectPlugin(_)
    | DisconnectPlugin
    | ActivatePlugin
    | DeactivatePlugin => error(PluginNotExisting, command, context)
    };

let execute: Behaviour.execute(state, command, event, error) =
  (. state, command, context, error) => {
    switch (state) {
    | Detected =>
      switch (command) {
      | ConnectPlugin(pluginDefinition, apiFragmentDescriptions) => [
          PluginConnected(pluginDefinition, apiFragmentDescriptions),
        ]
      | Heartbeat => [UnknownPluginDetected]
      | DisconnectPlugin
      | ActivatePlugin
      | DeactivatePlugin => []
      }
    | Connected(pluginDefinition, apiFragmentDescriptions) =>
      switch (command) {
      | DisconnectPlugin => [
          PluginDisconnected(pluginDefinition, apiFragmentDescriptions),
        ]
      | DeactivatePlugin => [
          PluginDeactivated(pluginDefinition, apiFragmentDescriptions),
        ]
      | Heartbeat
      | ConnectPlugin(_)
      | ActivatePlugin => error(PluginIsConnected, command, context)
      }
    | Disconnected(pluginDefinition, apiFragmentDescriptions) =>
      switch (command) {
      | Heartbeat => [
          PluginReconnected(pluginDefinition, apiFragmentDescriptions),
        ]
      | DeactivatePlugin => [
          PluginDeactivated(pluginDefinition, apiFragmentDescriptions),
        ]
      | ConnectPlugin(_)
      | DisconnectPlugin
      | ActivatePlugin => error(PluginIsDisconnected, command, context)
      }
    | Inactive(pluginDefinition, apiFragmentDescriptions) =>
      switch (command) {
      | ActivatePlugin => [
          PluginActivated(pluginDefinition, apiFragmentDescriptions),
        ]
      | Heartbeat
      | ConnectPlugin(_)
      | DisconnectPlugin
      | DeactivatePlugin => error(PluginIsInactive, command, context)
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
      | PluginConnected(pluginDefinition, apiFragmentDescriptions) =>
        Connected(pluginDefinition, apiFragmentDescriptions)
      | UnknownPluginDetected => state
      | PluginReconnected(_)
      | PluginDisconnected(_)
      | PluginActivated(_)
      | PluginDeactivated(_) =>
        raise(Reventless.Message.InvalidEvent(event_encode(event)))
      }
    | Connected(pluginDefinition, apiFragmentDescriptions) =>
      switch (event) {
      | PluginDisconnected(_) =>
        Disconnected(pluginDefinition, apiFragmentDescriptions)
      | PluginDeactivated(_) =>
        Inactive(pluginDefinition, apiFragmentDescriptions)
      | UnknownPluginDetected
      | PluginConnected(_)
      | PluginReconnected(_)
      | PluginActivated(_) =>
        raise(Reventless.Message.InvalidEvent(event_encode(event)))
      }
    | Disconnected(pluginDefinition, apiFragmentDescriptions) =>
      switch (event) {
      | PluginReconnected(_) =>
        Connected(pluginDefinition, apiFragmentDescriptions)
      | PluginDeactivated(_) =>
        Inactive(pluginDefinition, apiFragmentDescriptions)
      | UnknownPluginDetected
      | PluginConnected(_)
      | PluginDisconnected(_)
      | PluginActivated(_) =>
        raise(Reventless.Message.InvalidEvent(event_encode(event)))
      }
    | Inactive(pluginDefinition, apiFragmentDescriptions) =>
      switch (event) {
      | PluginActivated(_) =>
        Disconnected(pluginDefinition, apiFragmentDescriptions)
      | UnknownPluginDetected
      | PluginConnected(_)
      | PluginReconnected(_)
      | PluginDisconnected(_)
      | PluginDeactivated(_) =>
        raise(Reventless.Message.InvalidEvent(event_encode(event)))
      }
    };
  };
