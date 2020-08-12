open Reventless;
open PluginSpec;

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
    | DisconnectPlugin =>
      error(PluginDoesNotExist, command, context);
      [];
    };

let execute: Behaviour.execute(state, command, event, error) =
  (. state, command, context, error, _) => {
    switch (command) {
    | Heartbeat => []
    | ConnectPlugin(plugin) => [PluginConnected(plugin)]
    | DisconnectPlugin => [PluginDisconnected]
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
      raise(Reventless.Message.InvalidEvent(PluginSpec.event_encode(event)))
    };

let apply: Behaviour.apply(state, event) =
  (. state: state, event) => {
    let plugin =
      switch (state) {
      | Detected =>
        raise(
          Reventless.Message.InvalidEvent(PluginSpec.event_encode(event)),
        )
      | Connected(plugin)
      | Disconnected(plugin)
      | Inactive(plugin) => plugin
      };

    switch (event) {
    | UnknownPluginDetected =>
      raise(Reventless.Message.InvalidEvent(PluginSpec.event_encode(event)))
    | PluginConnected(plugin) => Connected(plugin)
    | PluginDisconnected
    | PluginActivated => Disconnected(plugin)
    | PluginDeactivated => Inactive(plugin)
    };
  };
