open PluginSpec
open Reventless.Plugin

module Spec = PluginSpec

@schema
type state =
  | NotConnected
  | Detected
  | Connected(pluginDefinition)
  | Disconnected(pluginDefinition)
  | Inactive(pluginDefinition)

let initialState = NotConnected

let resolverConfig = {
  {
    Reventless.Behavior.commandSchema,
    fields: ["Plugin_Activate", "Plugin_Deactivate"],
  }
}

let atomicCounter = None

let moduleUrl: string = %raw(`import.meta.url`)

let decide = (state, command) =>
  switch state {
  | NotConnected =>
    switch command {
    | Heartbeat => Ok([UnknownPluginDetected])
    | Connect(_)
    | Disconnect
    | Activate
    | Deactivate
    | ReportIncompatibility(_) =>
      Error(NotExisting)
    }
  | Detected =>
    switch command {
    | Connect(pluginDefinition) => Ok([(Connected(pluginDefinition): event)])
    | Heartbeat => Ok([UnknownPluginDetected])
    | ReportIncompatibility(pluginDefinition) => Ok([IncompatiblePluginDetected(pluginDefinition)])
    | Disconnect
    | Activate
    | Deactivate => Ok([])
    }
  | Connected(pluginDefinition) =>
    switch command {
    | Disconnect => Ok([Disconnected(pluginDefinition)])
    | Deactivate => Ok([Deactivated(pluginDefinition)])
    | Heartbeat => Ok([]) // ignore
    | ReportIncompatibility(incompatibleDef) => Ok([IncompatiblePluginDetected(incompatibleDef)])
    | Connect(_)
    | Activate =>
      Error(AlreadyConnected)
    }
  | Disconnected(pluginDefinition) =>
    switch command {
    | Heartbeat => Ok([Reconnected(pluginDefinition)])
    | Deactivate => Ok([Deactivated(pluginDefinition)])
    | ReportIncompatibility(incompatibleDef) => Ok([IncompatiblePluginDetected(incompatibleDef)])
    | Connect(_)
    | Disconnect
    | Activate =>
      Error(IsDisconnected)
    }
  | Inactive(pluginDefinition) =>
    switch command {
    | Activate => Ok([Activated(pluginDefinition)])
    | Heartbeat => Ok([]) // ignore
    | ReportIncompatibility(incompatibleDef) => Ok([IncompatiblePluginDetected(incompatibleDef)])
    | Connect(_)
    | Disconnect
    | Deactivate =>
      Error(IsInactive)
    }
  }

let evolve = (state: state, event) =>
  switch state {
  | NotConnected =>
    switch event {
    | UnknownPluginDetected => Detected
    | Connected(pluginDefinition) => Connected(pluginDefinition)
    | IncompatiblePluginDetected(_) => state
    | Reconnected(_)
    | Disconnected(_)
    | Activated(_)
    | Deactivated(_) =>
      throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
    }
  | Detected =>
    switch event {
    | UnknownPluginDetected => state
    | Connected(pluginDefinition) => Connected(pluginDefinition)
    | IncompatiblePluginDetected(_) => state
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
    | IncompatiblePluginDetected(_) => state
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
    | IncompatiblePluginDetected(_) => state
    | UnknownPluginDetected
    | Connected(_)
    | Disconnected(_)
    | Activated(_) =>
      throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
    }
  | Inactive(pluginDefinition) =>
    switch event {
    | Activated(_) => Disconnected(pluginDefinition)
    | IncompatiblePluginDetected(_) => state
    | UnknownPluginDetected
    | Connected(_)
    | Reconnected(_)
    | Disconnected(_)
    | Deactivated(_) =>
      throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
    }
  }
