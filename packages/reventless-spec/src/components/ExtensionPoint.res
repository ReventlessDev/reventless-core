module type Spec = {
  module Id = Id.String

  let name: string

  @decco
  type command
  @decco
  type event
  @decco
  type callCommand
}
