include ReventlessSpec.Behavior

module type Spec = {
  @schema
  type command

  @schema
  type event

  @schema
  type error
}

type init<'state, 'event> = 'event => 'state
type apply<'state, 'event> = ('state, 'event) => 'state

type create<'command, 'event, 'error> = (
  'command,
  Message.context,
  Message.errorHandler<'error, 'command, 'event>,
) => array<'event>

type execute<'state, 'command, 'event, 'error> = (
  'state,
  'command,
  Message.context,
  Message.errorHandler<'error, 'command, 'event>,
) => array<'event>
