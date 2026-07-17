include Reventless.Behavior

module type Spec = {
  @schema
  type command

  @schema
  type event

  @schema
  type error
}

type evolve<'state, 'event> = ('state, 'event) => 'state
type decide<'state, 'command, 'event, 'error> = (
  'state,
  'command,
) => result<array<'event>, 'error>
