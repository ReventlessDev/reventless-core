type t =
  | Aggregate
  | AtomicCounter
  | Plugin
  | CommandGenerator
  | CommandTopic
  | EventCollector
  | EventLog
  | EventMapper
  | EventTopic
  | ExtensionPoint
  | QueryDb
  | ReadModel
  | ReadModels
  | Scheduler
  | Service
  | Task
  | Vpc
  | Core;

let toString =
  fun
  | Aggregate => "Aggregate"
  | AtomicCounter => "AtomicCounter"
  | Plugin => "Plugin"
  | CommandGenerator => "CommandGenerator"
  | CommandTopic => "CommandTopic"
  | EventCollector => "EventCollector"
  | EventLog => "EventLog"
  | EventMapper => "EventMapper"
  | EventTopic => "EventTopic"
  | ExtensionPoint => "ExtensionPoint"
  | QueryDb => "QueryDB"
  | ReadModel => "ReadModel"
  | ReadModels => "ReadModels"
  | Scheduler => "Scheduler"
  | Service => "Service"
  | Task => "Task"
  | Vpc => "Vpc"
  | Core => "Core";

let ofString =
  fun
  | "Aggregate" => Aggregate->Some
  | "AtomicCounter" => AtomicCounter->Some
  | "Plugin" => Plugin->Some
  | "CommandGenerator" => CommandGenerator->Some
  | "CommandTopic" => CommandTopic->Some
  | "EventCollector" => EventCollector->Some
  | "EventLog" => EventLog->Some
  | "EventMapper" => EventMapper->Some
  | "EventTopic" => EventTopic->Some
  | "QueryDB" => QueryDb->Some
  | "ReadModel" => ReadModel->Some
  | "ReadModels" => ReadModels->Some
  | "Scheduler" => Scheduler->Some
  | "Service" => Service->Some
  | "Task" => Task->Some
  | "Vpc" => Vpc->Some
  | "Core" => Core->Some
  | _ => None;

let name = (name, t) => name ++ t->toString;
