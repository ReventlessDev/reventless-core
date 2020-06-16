type t =
  | Aggregate
  | AtomicCounter
  | Backend
  | CommandGenerator
  | CommandTopic
  | Context
  | EventCollector
  | EventLog
  | EventMapper
  | EventTopic
  | QueryDb
  | ReadModel
  | ReadModels
  | Scheduler
  | Service
  | Task
  | Vpc;

let toString =
  fun
  | Aggregate => "Aggregate"
  | AtomicCounter => "AtomicCounter"
  | Backend => "Backend"
  | CommandGenerator => "CommandGenerator"
  | CommandTopic => "CommandTopic"
  | Context => "Context"
  | EventCollector => "EventCollector"
  | EventLog => "EventLog"
  | EventMapper => "EventMapper"
  | EventTopic => "EventTopic"
  | QueryDb => "QueryDB"
  | ReadModel => "ReadModel"
  | ReadModels => "ReadModels"
  | Scheduler => "Scheduler"
  | Service => "Service"
  | Task => "Task"
  | Vpc => "Vpc";

let ofString =
  fun
  | "Aggregate" => Aggregate->Some
  | "AtomicCounter" => AtomicCounter->Some
  | "Backend" => Backend->Some
  | "CommandGenerator" => CommandGenerator->Some
  | "CommandTopic" => CommandTopic->Some
  | "Context" => Context->Some
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
  | _ => None;

let name = (name, t) => name ++ t->toString;
