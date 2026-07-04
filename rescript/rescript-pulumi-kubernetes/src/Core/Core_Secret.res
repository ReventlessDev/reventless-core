/** @pulumi/kubernetes core/v1 Secret
  see: https://www.pulumi.com/registry/packages/kubernetes/api-docs/core/v1/secret/
*/
type t = {
  id: Pulumi.Output.t<string>,
  apiVersion: Pulumi.Output.t<string>,
  kind: Pulumi.Output.t<string>,
  metadata: Pulumi.Output.t<Meta.objectMeta>,
}

type args = {
  metadata?: Pulumi.Input.t<Meta.objectMeta>,
  /** Plain-text values; the provider base64-encodes them into `data`. */
  stringData?: Pulumi.Input.t<dict<string>>,
  /** Already-base64-encoded values. */
  data?: Pulumi.Input.t<dict<string>>,
  @as("type") type_?: Pulumi.Input.t<string>,
  immutable?: Pulumi.Input.t<bool>,
}

@module("@pulumi/kubernetes") @scope(("core", "v1")) @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?, unit) => t =
  "Secret"
