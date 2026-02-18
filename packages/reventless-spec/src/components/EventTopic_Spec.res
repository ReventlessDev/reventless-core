module type T = {
  module Id: Id.T

  @schema
  type event
}
