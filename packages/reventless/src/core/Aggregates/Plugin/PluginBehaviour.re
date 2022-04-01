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
    fields: [|"Plugin_Activate", "Plugin_Deactivate"|],
  };

let atomicCounter = None;

let create: Behaviour.create(command, event, error) =
  (. command, context, error) =>
    switch (command) {
    | Heartbeat => [UnknownPluginDetected]
    | Connect(_)
    | Disconnect
    | Activate
    | Deactivate => error(NotExisting, command, context)
    };

let execute: Behaviour.execute(state, command, event, error) =
  (. state, command, context, error) => {
    switch (state) {
    | Detected =>
      switch (command) {
      | Connect(pluginDefinition) => [(Connected(pluginDefinition): event)]
      | Heartbeat => [UnknownPluginDetected]
      | Disconnect
      | Activate
      | Deactivate => []
      }
    | Connected(pluginDefinition) =>
      switch (command) {
      | Disconnect => [Disconnected(pluginDefinition)]
      | Deactivate => [Deactivated(pluginDefinition)]
      | Heartbeat => [] // ignore
      | Connect(_)
      | Activate => error(AlreadyConnected, command, context)
      }
    | Disconnected(pluginDefinition) =>
      switch (command) {
      | Heartbeat => [Reconnected(pluginDefinition)]
      | Deactivate => [Deactivated(pluginDefinition)]
      | Connect(_)
      | Disconnect
      | Activate => error(IsDisconnected, command, context)
      }
    | Inactive(pluginDefinition) =>
      switch (command) {
      | Activate => [Activated(pluginDefinition)]
      | Heartbeat => [] // ignore
      | Connect(_)
      | Disconnect
      | Deactivate => error(IsInactive, command, context)
      }
    };
  };

let init: Behaviour.init(state, event) =
  (. event) =>
    switch (event) {
    | UnknownPluginDetected => Detected
    | Connected(_)
    | Reconnected(_)
    | Disconnected(_)
    | Activated(_)
    | Deactivated(_) =>
      raise(Reventless.Message.InvalidEvent(event_encode(event)))
    };

let apply: Behaviour.apply(state, event) =
  (. state: state, event) => {
    switch (state) {
    | Detected =>
      switch (event) {
      | UnknownPluginDetected => state
      | Connected(pluginDefinition) => Connected(pluginDefinition)
      | Reconnected(_)
      | Disconnected(_)
      | Activated(_)
      | Deactivated(_) =>
        raise(Reventless.Message.InvalidEvent(event_encode(event)))
      }
    | Connected(pluginDefinition) =>
      switch (event) {
      | Disconnected(_) => Disconnected(pluginDefinition)
      | Deactivated(_) => Inactive(pluginDefinition)
      | UnknownPluginDetected
      | Connected(_)
      | Reconnected(_)
      | Activated(_) =>
        raise(Reventless.Message.InvalidEvent(event_encode(event)))
      }
    | Disconnected(pluginDefinition) =>
      switch (event) {
      | Reconnected(_) => Connected(pluginDefinition)
      | Deactivated(_) => Inactive(pluginDefinition)
      | UnknownPluginDetected
      | Connected(_)
      | Disconnected(_)
      | Activated(_) =>
        raise(Reventless.Message.InvalidEvent(event_encode(event)))
      }
    | Inactive(pluginDefinition) =>
      switch (event) {
      | Activated(_) => Disconnected(pluginDefinition)
      | UnknownPluginDetected
      | Connected(_)
      | Reconnected(_)
      | Disconnected(_)
      | Deactivated(_) =>
        raise(Reventless.Message.InvalidEvent(event_encode(event)))
      }
    };
  };
