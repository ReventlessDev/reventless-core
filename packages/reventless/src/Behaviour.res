type resolverConfig<'command> = {
  commandDecoder: Js.Json.t => Belt.Result.t<'command, Decco.decodeError>,
  fields: array<string>,
}

type init<'state, 'event> = 'event => 'state
type apply<'state, 'event> = ('state, 'event) => 'state

type create<'command, 'event, 'error> = (
  . 'command,
  Message.context,
  Message.errorHandler<'error, 'command, 'event>,
) => array<'event>

type execute<'state, 'command, 'event, 'error> = (
  . 'state,
  'command,
  Message.context,
  Message.errorHandler<'error, 'command, 'event>,
) => array<'event>

module type Spec = {
  @decco
  type command

  @decco
  type event

  @decco
  type error
}

module type T = {
  module Spec: Spec

  type state

  let resolverConfig: resolverConfig<Spec.command>

  let init: init<state, Spec.event>
  let apply: apply<state, Spec.event>

  let create: create<Spec.command, Spec.event, Spec.error>
  let execute: execute<state, Spec.command, Spec.event, Spec.error>
}
