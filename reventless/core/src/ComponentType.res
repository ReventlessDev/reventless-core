// A component's kind. Its text is the case's own name, but for `QueryDb`, deployed as
// `QueryDB`: a component's Pulumi type token, the `reventless:kind` tag and a
// runtime's `runtimeKind` carry it, so a word here is stored by every deployment.
type t =
  | Aggregate
  | Counter
  | Plugin
  | Platform
  | CommandGenerator
  | CommandTopic
  | EventCollector
  | EventLog
  | EventMapper
  | EventTopic
  | ExtensionPoint
  | Extension
  | @as("QueryDB") QueryDb
  | ReadModel
  | Scheduler
  | Service
  | SideEffectHandler
  | Task
  | Vpc
  | Heartbeat
  | Cloner
  | DcbEventLog
  | StateChangeSlice
  | StateViewSlice
  | AutomationSlice
  | OutboundTranslationSlice
  | InboundTranslationSlice

let all = [
  Aggregate,
  Counter,
  Plugin,
  Platform,
  CommandGenerator,
  CommandTopic,
  EventCollector,
  EventLog,
  EventMapper,
  EventTopic,
  ExtensionPoint,
  Extension,
  QueryDb,
  ReadModel,
  Scheduler,
  Service,
  SideEffectHandler,
  Task,
  Vpc,
  Heartbeat,
  Cloner,
  DcbEventLog,
  StateChangeSlice,
  StateViewSlice,
  AutomationSlice,
  OutboundTranslationSlice,
  InboundTranslationSlice,
]

let toString = (componentType: t): string => (componentType :> string)

let ofString = (str: string): option<t> => all->Array.find(t => toString(t) == str)

// The short name a component's resources are named with. A second spelling on
// purpose: it is part of every physical resource name already deployed.
let toName = componentType =>
  switch componentType {
  | Aggregate => "Aggr"
  | Counter => "Counter"
  | Plugin => "Plugin"
  | Platform => "Platform"
  | CommandGenerator => "CmdGen"
  | CommandTopic => "CmdTopic"
  | EventCollector => "EventColl"
  | EventLog => "EventLog"
  | EventMapper => "EventMapper"
  | EventTopic => "EventTopic"
  | ExtensionPoint => "ExtPoint"
  | Extension => "Extension"
  | QueryDb => "QueryDb"
  | ReadModel => "ReadModel"
  | Scheduler => "Scheduler"
  | Service => "Service"
  | SideEffectHandler => "SideEffectHandler"
  | Task => "Task"
  | Vpc => "Vpc"
  | Heartbeat => "Heartbeat"
  | Cloner => "Cloner"
  | DcbEventLog => "DcbEventLog"
  | StateChangeSlice => "StateChangeSlice"
  | StateViewSlice => "StateViewSlice"
  | AutomationSlice => "AutomationSlice"
  | OutboundTranslationSlice => "OutboundTranslationSlice"
  | InboundTranslationSlice => "InboundTranslationSlice"
  }

let name = (name, t) => name ++ t->toName
let nameOpt = (name, t) => name->Option.getOr("") ++ t->toName
