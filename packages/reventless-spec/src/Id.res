module type T = {
  @decco
  type t
  type input
  let make: input => t
  let makeFromString: string => t
  let toString: t => string
  let cmp: (t, t) => int
}

module StringPure = {
  @decco
  type t = string
  type input = string
  external make: t => t = "%identity"
  external makeFromString: string => t = "%identity"
  external toString: t => t = "%identity"
  let cmp = String.compare
}

module String: T = StringPure