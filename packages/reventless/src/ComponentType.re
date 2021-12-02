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
  | Cloner;

let toString =
  fun
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
  | Cloner => "Cloner";

let ofString =
  fun
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
  | _ => None;

let toName =
  fun
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
  | Cloner => "Cloner";

let name = (name, t) => name ++ t->toName;
