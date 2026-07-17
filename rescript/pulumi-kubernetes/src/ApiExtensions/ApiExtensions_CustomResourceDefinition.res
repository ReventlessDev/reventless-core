/** @pulumi/kubernetes apiextensions/v1 CustomResourceDefinition
  see: https://www.pulumi.com/registry/packages/kubernetes/api-docs/apiextensions/v1/customresourcedefinition/

  The CRD `spec` (group / versions / schema / names / scope) is large and
  rarely hand-written in ReScript; it is kept opaque as `JSON.t`. Register a
  CRD to teach the cluster a new kind, then create instances of it with
  `ApiExtensions.CustomResource`.
*/
type t = {
  id: Pulumi.Output.t<string>,
  apiVersion: Pulumi.Output.t<string>,
  kind: Pulumi.Output.t<string>,
  metadata: Pulumi.Output.t<Meta.objectMeta>,
}

type args = {
  metadata?: Pulumi.Input.t<Meta.objectMeta>,
  spec: Pulumi.Input.t<JSON.t>,
}

@module("@pulumi/kubernetes") @scope(("apiextensions", "v1")) @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?, unit) => t =
  "CustomResourceDefinition"
