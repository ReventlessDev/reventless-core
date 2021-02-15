type aggregateName = string;

type action('id, 'command) =
  | PublishToQueue(
      string,
      ('id, 'command),
      Message.encoder('id),
      Message.encoder('command),
    )
  | PublishToQueueAsync(
      Js.Promise.t(
        (
          string,
          ('id, 'command),
          Message.encoder('id),
          Message.encoder('command),
        ),
      ),
    )
  | Call(Message.handler('command), 'command)
  | Nothing; // TODO: Since mappings changed to return array(action), this could be removed because it means the same like an empty array of actions

module type T = {
  type eventId;
  type event;
  type action;

  let eventIdDecoder: Message.decoder(eventId);
  let eventDecoder: Message.decoder(event);

  let map: (. eventId, event) => array(action);
};

module type Mappings = {
  type commandId;
  type command;

  let name: aggregateName;

  let mappings:
    Js.Dict.t(module T with type action = action(commandId, command));
};
