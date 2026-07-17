/** @pulumi/kubernetes core/v1 Namespace
  see: https://www.pulumi.com/registry/packages/kubernetes/api-docs/core/v1/namespace/
*/
type t = {
  id: Pulumi.Output.t<string>,
  apiVersion: Pulumi.Output.t<string>,
  kind: Pulumi.Output.t<string>,
  metadata: Pulumi.Output.t<Meta.objectMeta>,
}

type args = {metadata?: Pulumi.Input.t<Meta.objectMeta>}

@module("@pulumi/kubernetes") @scope(("core", "v1")) @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?, unit) => t =
  "Namespace"
