module type Spec = {
  module Id: Id.T

  let name: string

  @schema
  type command

  @schema
  type event

  @schema
  type error
}
