type t =
  | Aggregate
  | Counter
  | Plugin
  | CommandGenerator
  | CommandTopic
  | EventCollector
  | EventLog
  | EventMapper
  | EventTopic
  | ExtensionPoint
  | Extension
  | QueryDb
  | ReadModel
  | Scheduler
  | Service
  | SideEffectHandler
  | Task
  | Vpc
  | Core
  | Heartbeat
  | Cloner
  | DcbEventLog
  | CommandHandler

let toString = componentType =>
  switch componentType {
  | Aggregate => "Aggregate"
  | Counter => "Counter"
  | Plugin => "Plugin"
  | CommandGenerator => "CommandGenerator"
  | CommandTopic => "CommandTopic"
  | EventCollector => "EventCollector"
  | EventLog => "EventLog"
  | EventMapper => "EventMapper"
  | EventTopic => "EventTopic"
  | ExtensionPoint => "ExtensionPoint"
  | Extension => "Extension"
  | QueryDb => "QueryDB"
  | ReadModel => "ReadModel"
  | Scheduler => "Scheduler"
  | Service => "Service"
  | SideEffectHandler => "SideEffectHandler"
  | Task => "Task"
  | Vpc => "Vpc"
  | Core => "Core"
  | Heartbeat => "Heartbeat"
  | Cloner => "Cloner"
  | DcbEventLog => "DcbEventLog"
  | CommandHandler => "CommandHandler"
  }

let ofString = str =>
  switch str {
  | "Aggregate" => Aggregate->Some
  | "Counter" => Counter->Some
  | "Plugin" => Plugin->Some
  | "CommandGenerator" => CommandGenerator->Some
  | "CommandTopic" => CommandTopic->Some
  | "EventCollector" => EventCollector->Some
  | "EventLog" => EventLog->Some
  | "EventMapper" => EventMapper->Some
  | "EventTopic" => EventTopic->Some
  | "ExtensionPoint" => ExtensionPoint->Some
  | "Extension" => Extension->Some
  | "QueryDB" => QueryDb->Some
  | "ReadModel" => ReadModel->Some
  | "Scheduler" => Scheduler->Some
  | "Service" => Service->Some
  | "SideEffectHandler" => SideEffectHandler->Some
  | "Task" => Task->Some
  | "Vpc" => Vpc->Some
  | "Core" => Core->Some
  | "Heartbeat" => Heartbeat->Some
  | "Cloner" => Cloner->Some
  | "DcbEventLog" => DcbEventLog->Some
  | "CommandHandler" => CommandHandler->Some
  | _ => None
  }

let toName = componentType =>
  switch componentType {
  | Aggregate => "Aggr"
  | Counter => "Counter"
  | Plugin => "Plugin"
  | CommandGenerator => "CmdGen"
  | CommandTopic => "CmdTopic"
  | EventCollector => "EventColl"
  | EventLog => "EventLog"
  | EventMapper => "EventMapper"
  | EventTopic => "EventTopic"
  | ExtensionPoint => "ExtPoint"
  | Extension => "Extension"
  | QueryDb => "QueryDB"
  | ReadModel => "ReadModel"
  | Scheduler => "Scheduler"
  | Service => "Service"
  | SideEffectHandler => "SideEffectHandler"
  | Task => "Task"
  | Vpc => "Vpc"
  | Core => "Core"
  | Heartbeat => "Heartbeat"
  | Cloner => "Cloner"
  | DcbEventLog => "DcbEventLog"
  | CommandHandler => "CmdHandler"
  }

let name = (name, t) => name ++ t->toName
let nameOpt = (name, t) => name->Option.getOr("") ++ t->toName
