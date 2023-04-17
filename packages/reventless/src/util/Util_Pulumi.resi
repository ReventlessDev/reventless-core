module Output: {
  module Async: {
    @ocaml.doc(" Use an Output before you actually know the value.
     ")
    type t<'a> = (Pulumi.Output.t<'a>, (. Pulumi.Output.t<'a>) => unit)

    @ocaml.doc(" create a new async output
     *
     *  NOTE: The set function needs to be called in deploytime code
     *        while the output itself needs to be used in runtime-code.
     *        Otherwise, just use Pulumi's Output functions (e.g. all, apply)
     *        to prevent possible dependency-cycles.
     ")
    let make: unit => t<'a>
  }
}

module ComponentResourceOptions: {
  let ofCustomResourceOptions: Pulumi.CustomResourceOptions.t => Pulumi.ComponentResource.Options.t
}
