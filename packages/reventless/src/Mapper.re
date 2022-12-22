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
  let name: string;
  type event;
  let event_decode: decode(event); // TODO: is it possible to remove Decco here?
};

module MakeGenericSourceFromEventSource =
       (EventSource: EventSource)
       : (GenericSource with type t = EventSource.event) => {
  let name = EventSource.name;
  type t = EventSource.event;
  let decode = EventSource.event_decode;
};

module type CommandTarget = {
  let name: string;
  type command;
  let command_decode: Js.Json.t => Belt.Result.t(command, Decco.decodeError); // TODO: is it possible to remove Decco here?
  let command_encode: command => Js.Json.t;
};

module MakeGenericTargetFromCommandTarget =
       (CommandTarget: CommandTarget)
       : (GenericTarget with type t = CommandTarget.command) => {
  let name = CommandTarget.name;
  type t = CommandTarget.command;
  let decode = CommandTarget.command_decode;
  let encode = CommandTarget.command_encode;
};
