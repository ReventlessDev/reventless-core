type encode<'a> = 'a => Js.Json.t
type decode<'a> = Js.Json.t => result<'a, Decco.decodeError>

module type GenericSource = {
  let name: string
  type t
  let decode: decode<t> // TODO: is it possible to remove Decco here?
}

module type GenericTarget = {
  let name: string
  type t
  let decode: decode<t> // TODO: is it possible to remove Decco here?
  let encode: encode<t>
}

module type EventSource = {
  module Id: ReventlessSpec.Id.T
  let name: string
  type event
  let event_decode: decode<event> // TODO: is it possible to remove Decco here?
}

module MakeGenericSourceFromEventSource = (EventSource: ReventlessSpec.Projection.Mapping): (
  GenericSource with type t = Message.event'<string, EventSource.sourceEvent>
) => {
  let name = EventSource.sourceName
  type t = Message.event'<string, EventSource.sourceEvent>
  let decode = json =>
    json
    ->(Message.event'_decode(EventSource.SourceId.t_decode, EventSource.sourceEvent_decode, _))
    ->Result.map(({id, meta, event}) => {
      ReventlessSpec.Message.id: id->EventSource.SourceId.toString,
      meta,
      event,
    })
}

module type CommandTarget = {
  let name: string
  type command
  let command_decode: Js.Json.t => result<command, Decco.decodeError> // TODO: is it possible to remove Decco here?
  let command_encode: command => Js.Json.t
}

// TODO: en/decode command'
module MakeGenericTargetFromCommandTarget = (CommandTarget: CommandTarget): (
  GenericTarget with type t = CommandTarget.command
) => {
  let name = CommandTarget.name
  type t = CommandTarget.command
  let decode = CommandTarget.command_decode
  let encode = CommandTarget.command_encode
}
