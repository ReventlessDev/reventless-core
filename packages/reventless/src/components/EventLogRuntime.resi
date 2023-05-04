let eventToJson: (
  'specId => Js.Json.t,
  'specEvent => Js.Json.t,
  'specId,
  Reventless.Message.event'<'specId, 'specEvent>,
) => Js.Json.t

let eventsToJson: (
  array<Reventless.Message.event'<'specId, 'specEvent>>,
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
  Reventless.EventTopic.publish<'specId, 'specEvent>,
  'specId => string,
  'specId,
  array<Reventless.Message.event'<'specId, 'specEvent>>,
) => promise<unit>

let catchErrorHandler: exn => 'a

let appendFn: (
  Reventless.EventLogCommon.append<string, Js.Json.t>,
  'specId => string,
  'specId => Js.Json.t,
  'specEvent => Js.Json.t,
  Reventless.EventTopic.publish<'specId, 'specEvent>,
  string,
) => (
  . int,
  'specId,
  array<Reventless.Message.event'<'specId, 'specEvent>>,
) => promise<Belt.Result.t<unit, string>>

let decodeEvent: (Js.Json.t => Belt.Result.t<'a, Decco.decodeError>, Js.Json.t) => 'a

let decodeEvents: (
  Belt.Array.t<Js.Json.t>,
  Js.Json.t => Belt.Result.t<'a, Decco.decodeError>,
) => array<'a>

let decodeEventsToPromise: (
  Js.Json.t => result<'a, Decco.decodeError>,
  array<Js.Json.t>,
) => promise<array<'a>>

let replayFn: (
  Reventless.EventLogCommon.replay<string, Js.Json.t>,
  'specId => string,
  Js.Json.t => result<'specEvent, Decco.decodeError>,
) => (. 'specId) => promise<array<'specEvent>>
