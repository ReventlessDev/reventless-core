/** @pulumi/kubernetes core/v1 ConfigMap
  see: https://www.pulumi.com/registry/packages/kubernetes/api-docs/core/v1/configmap/
*/
type t = {
  id: Pulumi.Output.t<string>,
  apiVersion: Pulumi.Output.t<string>,
  kind: Pulumi.Output.t<string>,
  metadata: Pulumi.Output.t<Meta.objectMeta>,
}

type args = {
  metadata?: Pulumi.Input.t<Meta.objectMeta>,
  data?: Pulumi.Input.t<dict<string>>,
  binaryData?: Pulumi.Input.t<dict<string>>,
  immutable?: Pulumi.Input.t<bool>,
}

@module("@pulumi/kubernetes") @scope(("core", "v1")) @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?, unit) => t =
  "ConfigMap"
