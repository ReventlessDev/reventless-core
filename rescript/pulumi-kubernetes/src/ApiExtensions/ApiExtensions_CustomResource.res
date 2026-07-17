/** @pulumi/kubernetes apiextensions.CustomResource — the generic escape hatch
  for any custom resource (a CR *instance*) without generated typings.
  see: https://www.pulumi.com/registry/packages/kubernetes/api-docs/apiextensions/customresource/

  Consumers who want typed CR classes generate them with `crd2pulumi` in their
  own package; this binding covers the untyped case.
*/
type t = {
  id: Pulumi.Output.t<string>,
  apiVersion: Pulumi.Output.t<string>,
  kind: Pulumi.Output.t<string>,
  metadata: Pulumi.Output.t<Meta.objectMeta>,
}

/** `apiVersion` and `kind` are required; `spec` is the CR's body. For CRs whose
  top-level shape is not `metadata`+`spec` (e.g. carrying `data`/`status`), use
  `makeRaw` with a fully-formed JSON object instead. */
type args = {
  apiVersion: string,
  kind: string,
  metadata?: Pulumi.Input.t<Meta.objectMeta>,
  spec?: Pulumi.Input.t<JSON.t>,
}

@module("@pulumi/kubernetes") @scope("apiextensions") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?, unit) => t =
  "CustomResource"

/** Fully-generic form: `args` is the entire resource body as JSON and must
  include `apiVersion` and `kind`. */
@module("@pulumi/kubernetes") @scope("apiextensions") @new
external makeRaw: (~name: string, ~args: JSON.t, ~opts: Pulumi.CustomResourceOptions.t=?, unit) => t =
  "CustomResource"
