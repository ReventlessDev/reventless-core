open PluginSpec
open ReventlessSpec.Plugin

module Spec = PluginSpec

@schema
type state =
  | Detected
  | Connected(pluginDefinition)
  | Disconnected(pluginDefinition)
  | Inactive(pluginDefinition)

let resolverConfig = {
  {
    Behavior.commandSchema,
    fields: ["Plugin_Activate", "Plugin_Deactivate"],
  }
}

let atomicCounter = None

let create: Behavior.create<command, event, error> = (command, context, error) =>
  switch command {
  | Heartbeat => [UnknownPluginDetected]
  | Connect(_)
  | Disconnect
  | Activate
  | Deactivate =>
    error(NotExisting, command, context)
  }

let execute: Behavior.execute<state, command, event, error> = (state, command, context, error) =>
  switch state {
  | Detected =>
    switch command {
    | Connect(pluginDefinition) => [(Connected(pluginDefinition): event)]
    | Heartbeat => [UnknownPluginDetected]
    | Disconnect
    | Activate
    | Deactivate => []
    }
  | Connected(pluginDefinition) =>
    switch command {
    | Disconnect => [Disconnected(pluginDefinition)]
    | Deactivate => [Deactivated(pluginDefinition)]
    | Heartbeat => [] // ignore
    | Connect(_)
    | Activate =>
      error(AlreadyConnected, command, context)
    }
  | Disconnected(pluginDefinition) =>
    switch command {
    | Heartbeat => [Reconnected(pluginDefinition)]
    | Deactivate => [Deactivated(pluginDefinition)]
    | Connect(_)
    | Disconnect
    | Activate =>
      error(IsDisconnected, command, context)
    }
  | Inactive(pluginDefinition) =>
    switch command {
    | Activate => [Activated(pluginDefinition)]
    | Heartbeat => [] // ignore
    | Connect(_)
    | Disconnect
    | Deactivate =>
      error(IsInactive, command, context)
    }
  }

let init: Behavior.init<state, event> = event =>
  switch event {
  | UnknownPluginDetected => Detected
  | Connected(_)
  | Reconnected(_)
  | Disconnected(_)
  | Activated(_)
  | Deactivated(_) =>
    raise(Message.InvalidEvent(event->Message.encode(eventSchema)))
  }

let apply: Behavior.apply<state, event> = (state: state, event) =>
  switch state {
  | Detected =>
    switch event {
    | UnknownPluginDetected => state
    | Connected(pluginDefinition) => Connected(pluginDefinition)
    | Reconnected(_)
    | Disconnected(_)
    | Activated(_)
    | Deactivated(_) =>
      raise(Message.InvalidEvent(event->Message.encode(eventSchema)))
    }
  | Connected(pluginDefinition) =>
    switch event {
    | Disconnected(_) => Disconnected(pluginDefinition)
    | Deactivated(_) => Inactive(pluginDefinition)
    | UnknownPluginDetected
    | Connected(_)
    | Reconnected(_)
    | Activated(_) =>
      raise(Message.InvalidEvent(event->Message.encode(eventSchema)))
    }
  | Disconnected(pluginDefinition) =>
    switch event {
    | Reconnected(_) => Connected(pluginDefinition)
    | Deactivated(_) => Inactive(pluginDefinition)
    | UnknownPluginDetected
    | Connected(_)
    | Disconnected(_)
    | Activated(_) =>
      raise(Message.InvalidEvent(event->Message.encode(eventSchema)))
    }
  | Inactive(pluginDefinition) =>
    switch event {
    | Activated(_) => Disconnected(pluginDefinition)
    | UnknownPluginDetected
    | Connected(_)
    | Reconnected(_)
    | Disconnected(_)
    | Deactivated(_) =>
      raise(Message.InvalidEvent(event->Message.encode(eventSchema)))
    }
  }
