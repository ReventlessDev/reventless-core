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
    ReventlessSpec.Behavior.commandSchema,
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
  | Deactivate
  | ReportIncompatibility(_) =>
    error(NotExisting, command, context)
  }

let execute: Behavior.execute<state, command, event, error> = (state, command, context, error) =>
  switch state {
  | Detected =>
    switch command {
    | Connect(pluginDefinition) => [(Connected(pluginDefinition): event)]
    | Heartbeat => [UnknownPluginDetected]
    | ReportIncompatibility(pluginDefinition) => [IncompatiblePluginDetected(pluginDefinition)]
    | Disconnect
    | Activate
    | Deactivate => []
    }
  | Connected(pluginDefinition) =>
    switch command {
    | Disconnect => [Disconnected(pluginDefinition)]
    | Deactivate => [Deactivated(pluginDefinition)]
    | Heartbeat => [] // ignore
    | ReportIncompatibility(incompatibleDef) => [IncompatiblePluginDetected(incompatibleDef)]
    | Connect(_)
    | Activate =>
      error(AlreadyConnected, command, context)
    }
  | Disconnected(pluginDefinition) =>
    switch command {
    | Heartbeat => [Reconnected(pluginDefinition)]
    | Deactivate => [Deactivated(pluginDefinition)]
    | ReportIncompatibility(incompatibleDef) => [IncompatiblePluginDetected(incompatibleDef)]
    | Connect(_)
    | Disconnect
    | Activate =>
      error(IsDisconnected, command, context)
    }
  | Inactive(pluginDefinition) =>
    switch command {
    | Activate => [Activated(pluginDefinition)]
    | Heartbeat => [] // ignore
    | ReportIncompatibility(incompatibleDef) => [IncompatiblePluginDetected(incompatibleDef)]
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
  | Deactivated(_)
  | IncompatiblePluginDetected(_) =>
    throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
  }

let apply: Behavior.apply<state, event> = (state: state, event) =>
  switch state {
  | Detected =>
    switch event {
    | UnknownPluginDetected => state
    | Connected(pluginDefinition) => Connected(pluginDefinition)
    | IncompatiblePluginDetected(_) => state // no state change; observation only
    | Reconnected(_)
    | Disconnected(_)
    | Activated(_)
    | Deactivated(_) =>
      throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
    }
  | Connected(pluginDefinition) =>
    switch event {
    | Disconnected(_) => Disconnected(pluginDefinition)
    | Deactivated(_) => Inactive(pluginDefinition)
    | IncompatiblePluginDetected(_) => state // no state change; observation only
    | UnknownPluginDetected
    | Connected(_)
    | Reconnected(_)
    | Activated(_) =>
      throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
    }
  | Disconnected(pluginDefinition) =>
    switch event {
    | Reconnected(_) => Connected(pluginDefinition)
    | Deactivated(_) => Inactive(pluginDefinition)
    | IncompatiblePluginDetected(_) => state // no state change; observation only
    | UnknownPluginDetected
    | Connected(_)
    | Disconnected(_)
    | Activated(_) =>
      throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
    }
  | Inactive(pluginDefinition) =>
    switch event {
    | Activated(_) => Disconnected(pluginDefinition)
    | IncompatiblePluginDetected(_) => state // no state change; observation only
    | UnknownPluginDetected
    | Connected(_)
    | Reconnected(_)
    | Disconnected(_)
    | Deactivated(_) =>
      throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
    }
  }
