let id = "id"

module Problem = {
  // this creates the following:
  // {
  //   id: Caml_option.some(Pulumi.output(id))
  // }
  // The problem is the combination of optional fields with Pulumi.Inputs,
  // because Pulumi.Input is implemented using JavaScript Proxy:
  //   https://github.com/pulumi/pulumi/blob/afac93f70cde7c89eb8c5820b490c917f540ef2e/sdk/nodejs/output.ts#L264
  //   https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Proxy
  // querying a non-existing field on a Proxy doesn't return undefined, and
  // so Caml_option.some returns
  //  { BS_PRIVATE_NESTED_SOME_NONE: 0 }
  // see: https://github.com/rescript-lang/playground/blob/ab1b82f19ad141fd954bf94aff4dbbbde364e3e0/stdlib/caml_option.js#L15
  // which leads to an exception in Pulumi:
  //   panic: fatal: An assertion has failed:
  //   Unexpected duplicate underscore: b_s__p_r_i_v_a_t_e__n_e_s_t_e_d__s_o_m_e__n_o_n_e
  // see: https://github.com/pulumi/pulumi-terraform-bridge/issues/62
  // 26.11.2024 - Seems to be resolved now
  type args = {id?: Input.t<string>}

  let args = {id: id->Output.make->Output.asInput}
  Js.Console.log2("Problem: args:", args)
}

module Option1 = {
  // without optional fields, everything is ok
  // but we need lots of optional fields for AWS configs !
  type args = {id: Input.t<string>}

  let args = {id: id->Output.make->Output.asInput}
  Js.Console.log2("Option1: args:", args)
}

module Option2 = {
  // without wrapping values into Pulumi.Input, everything is ok
  // but we need Pulumi.Input to retrieve values from dependend resources !
  type args = {id?: string}

  let args = {id: "id"}
  Js.Console.log2("Option2: args:", args)
}

module Option3 = {
  module Args = {
    // continue using Js.t with @obj to generate make function is also ok
    // but @obj is deprecated and will be removed in future versions !
    type t
    @obj
    external make: (~id: Input.t<string>=?) => t = ""
  }
  let args = Args.make(~id=id->Output.make->Output.asInput)
  Js.Console.log2("Option3: args:", args)
}
