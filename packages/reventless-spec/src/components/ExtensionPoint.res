module type Spec = {
  module Id = Id.String

  let name: string

  @schema
  type command
  @schema
  type event
  @schema
  type callCommand
}
