module type T = {
  module Id: Id.T

  let name: string

  @schema
  type event
}
