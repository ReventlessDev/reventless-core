type encode('a) = 'a => Js.Json.t;
type decode('a) = Js.Json.t => Belt.Result.t('a, Decco.decodeError);

module type GenericSource = {
  let name: string;
  type t;
  let decode: decode(t); // TODO: is it possible to remove Decco here?
};

module type GenericTarget = {
  let name: string;
  type t;
  let decode: decode(t); // TODO: is it possible to remove Decco here?
  let encode: encode(t);
};

module type EventSource = {
  module Id: ReventlessSpec.Id.T;
  let name: string;
  type event;
  let event_decode: decode(event); // TODO: is it possible to remove Decco here?
};

module MakeGenericSourceFromEventSource =
       (EventSource: EventSource)

         : (
           GenericSource with
             type t = Message.event'(string, EventSource.event)
       ) => {
  let name = EventSource.name;
  type t = Message.event'(string, EventSource.event);
  let decode = json =>
    json
    ->Message.event'_decode(
        EventSource.Id.t_decode,
        EventSource.event_decode,
        _,
      )
    ->Belt.Result.map(({id, meta, event}) =>
        {ReventlessSpec.Message.id: id->EventSource.Id.toString, meta, event}
      );
};

module type CommandTarget = {
  let name: string;
  type command;
  let command_decode: Js.Json.t => Belt.Result.t(command, Decco.decodeError); // TODO: is it possible to remove Decco here?
  let command_encode: command => Js.Json.t;
};

// TODO: en/decode command'
module MakeGenericTargetFromCommandTarget =
       (CommandTarget: CommandTarget)
       : (GenericTarget with type t = CommandTarget.command) => {
  let name = CommandTarget.name;
  type t = CommandTarget.command;
  let decode = CommandTarget.command_decode;
  let encode = CommandTarget.command_encode;
};
