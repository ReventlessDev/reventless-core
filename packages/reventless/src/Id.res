module StringPure = {
  @decco
  type t = string
  type input = string
  external make: t => t = "%identity"
  external makeFromString: string => t = "%identity"
  external toString: t => t = "%identity"
  let cmp = String.compare
}

module String: ReventlessSpec.Id.T = StringPure
