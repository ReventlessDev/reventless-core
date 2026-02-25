// Behavior module type for aggregate business logic.
// Lives in reventless-spec so application domain code can define behaviors
// without importing the reventless implementation package.
//
// A module satisfying this type is structurally compatible with Reventless.Behavior.T
// because all referenced types (Message.context, Handler.errorHandler) are identical
// in both packages.

type resolverConfig<'command> = {
  commandSchema: S.t<'command>,
  fields: array<string>,
}

module type T = {
  module Spec: {
    @schema
    type command

    @schema
    type event

    @schema
    type error
  }

  type state

  let resolverConfig: resolverConfig<Spec.command>

  let init: Spec.event => state
  let apply: (state, Spec.event) => state

  let create: (
    Spec.command,
    Message.context,
    Handler.errorHandler<Spec.error, Spec.command, Spec.event>,
  ) => array<Spec.event>

  let execute: (
    state,
    Spec.command,
    Message.context,
    Handler.errorHandler<Spec.error, Spec.command, Spec.event>,
  ) => array<Spec.event>
}
