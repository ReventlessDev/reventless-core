type decoder('a) = Js.Json.t => Belt.Result.t('a, Decco.decodeError);
type encoder('a) = 'a => Js.Json.t;

type mapper('event, 'command) = 'event => list('command);

type commandHandler('command) = 'command => Js.Promise.t(unit);

type action('id, 'command) =
  | PublishToQueue(
      string,
      ('id, 'command),
      encoder('id),
      encoder('command),
    )
  | Call(commandHandler('command), 'command)
  | Nothing; // TODO: Since mappings changed to return array(action), this could be removed because it means the same like an empty array of actions

module type T = {
  type eventId;
  type event;
  type action;

  let eventIdDecoder: decoder(eventId);
  let eventDecoder: decoder(event);

  let map: (. eventId, event) => array(action);
};

module type Mappings = {
  type commandId;
  type command;

  let name: string;

  let mappings:
    Js.Dict.t(module T with type action = action(commandId, command));
};
