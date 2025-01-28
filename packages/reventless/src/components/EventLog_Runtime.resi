let eventToJson: (
  'specId => Js.Json.t,
  'specEvent => Js.Json.t,
  'specId,
  ReventlessSpec.Message.event'<'specId, 'specEvent>,
) => Js.Json.t

let eventsToJson: (
  array<ReventlessSpec.Message.event'<'specId, 'specEvent>>,
  'specId => Js.Json.t,
  'specEvent => Js.Json.t,
  'specId,
) => array<Js.Json.t>

let storageAppendErrorHandler: (
  string,
  'specId => string,
  'specId,
  Js.Exn.t,
) => result<unit, string>

let publishToEventTopic: (
  EventTopic.publish<'specId, 'specEvent>,
  'specId => string,
  'specId,
  array<ReventlessSpec.Message.event'<'specId, 'specEvent>>,
) => promise<unit>

let catchErrorHandler: exn => 'a

let appendFn: (
  ReventlessSpec.EventLog.append<string, Js.Json.t>,
  'specId => string,
  'specId => Js.Json.t,
  'specEvent => Js.Json.t,
  EventTopic.publish<'specId, 'specEvent>,
  string,
) => (
  . int,
  'specId,
  array<ReventlessSpec.Message.event'<'specId, 'specEvent>>,
) => promise<Belt.Result.t<unit, string>>

let replayFn: (
  ReventlessSpec.EventLog.replay<string, Js.Json.t>,
  'specId => string,
  Js.Json.t => result<'specEvent, Decco.decodeError>,
) => (. 'specId) => promise<array<'specEvent>>
