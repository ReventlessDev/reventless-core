module type T = {
  module Id: Id.T

  let name: string

  @decco
  type command

  @decco
  type event

  @decco
  type error
}
