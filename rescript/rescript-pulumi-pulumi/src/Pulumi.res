/** @pulumi/pulumi see: https://www.pulumi.com/docs/reference/pkg/nodejs/pulumi/pulumi */
@module("@pulumi/pulumi")
external getStackName: unit => string = "getStack"

@module("@pulumi/pulumi")
external getProjectName: unit => string = "getProject"

// Pulumi reads ESM named exports or CJS module.exports as stack outputs.
// Since deploy functions run inside calls (not at module top level), we
// collect outputs in a shared dict. The entry point re-exports them.
let _outputs: dict<Output.t<JSON.t>> = Dict.make()

let export = (name: string, value: Output.t<'a>): unit =>
  _outputs->Dict.set(name, value->Obj.magic)

let getOutputs = (): dict<Output.t<JSON.t>> => _outputs
