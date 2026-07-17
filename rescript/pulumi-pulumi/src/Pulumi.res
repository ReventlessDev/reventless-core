/** @pulumi/pulumi see: https://www.pulumi.com/docs/reference/pkg/nodejs/pulumi/pulumi */
@module("@pulumi/pulumi")
external getStackName: unit => string = "getStack"

@module("@pulumi/pulumi")
external getProjectName: unit => string = "getProject"

// True during `pulumi preview` (dry run). Guard deploy-time side effects (e.g.
// one-shot SQS sends inside Output.apply) so they only run on a real `pulumi up`.
@module("@pulumi/pulumi/runtime/index.js")
external isDryRun: unit => bool = "isDryRun"

// Pulumi captures ALL top-level ESM named exports as stack outputs. ReScript
// hoists module bindings (Platform, Catalog) as named exports, leaking internal
// data (sury schemas, Spec modules) into `pulumi stack output`.
//
// To override: after all resources are created, call registerStackOutputs()
// on the stack resource, which replaces auto-captured outputs with only the
// values explicitly registered via Pulumi.export().
let _outputs: dict<Output.t<JSON.t>> = Dict.make()

let export = (name: string, value: Output.t<'a>): unit =>
  _outputs->Dict.set(name, value->Obj.magic)

@module("@pulumi/pulumi/runtime/index.js")
external _getStackResource: unit => option<{..}> = "getStackResource"

@send
external _stackRegisterOutputs: ({..}, dict<Output.t<JSON.t>>) => unit = "registerOutputs"

let getOutputs = (): dict<Output.t<JSON.t>> => {
  switch _getStackResource() {
  | Some(stack) => stack->_stackRegisterOutputs(_outputs)
  | None => ()
  }
  _outputs
}
