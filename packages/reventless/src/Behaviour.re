type resolverConfig('command) = {
  commandDecoder: Js.Json.t => Belt.Result.t('command, Decco.decodeError),
  fields: array(string),
};

type atomicCounterConfig('command) = {
  name: string,
  shouldIncrement: 'command => bool,
};

type init('state, 'event) = (. 'event) => 'state;
type apply('state, 'event) = (. 'state, 'event) => 'state;

type create('command, 'event, 'error) =
  (
    . 'command,
    Message.context,
    Message.errorHandler('error, 'command),
    option(int)
  ) =>
  list('event);

type execute('state, 'command, 'event, 'error) =
  (
    . 'state,
    'command,
    Message.context,
    Message.errorHandler('error, 'command),
    option(int)
  ) =>
  list('event);

exception NoCountProvided;

module type T = {
  type command;
  type event;
  type error;

  type state;

  let resolverConfig: resolverConfig(command);

  let atomicCounter: option(atomicCounterConfig(command));

  let init: init(state, event);
  let apply: apply(state, event);

  let create: create(command, event, error);
  let execute: execute(state, command, event, error);
};