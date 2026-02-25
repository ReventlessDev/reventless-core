module type T = {
  @schema
  type t
  type input
  let make: input => t
  let makeFromString: string => t
  let toString: t => string
  let cmp: (t, t) => Ordering.t
}

module StringPure = {
  @schema
  type t = string
  type input = string
  external make: t => t = "%identity"
  external makeFromString: string => t = "%identity"
  external toString: t => t = "%identity"
  let cmp: (t, t) => Ordering.t = String.compare
}

module String: T = StringPure
