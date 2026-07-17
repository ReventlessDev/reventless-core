/** @pulumi/kubernetes rbac.authorization.k8s.io/v1 ClusterRole
  see: https://www.pulumi.com/registry/packages/kubernetes/api-docs/rbac/v1/clusterrole/
*/
type t = {
  id: Pulumi.Output.t<string>,
  apiVersion: Pulumi.Output.t<string>,
  kind: Pulumi.Output.t<string>,
  metadata: Pulumi.Output.t<Meta.objectMeta>,
}

type args = {
  metadata?: Pulumi.Input.t<Meta.objectMeta>,
  rules?: Pulumi.Input.t<array<Rbac_Role.policyRule>>,
  /** aggregationRule selects other ClusterRoles to union in; kept opaque. */
  aggregationRule?: Pulumi.Input.t<JSON.t>,
}

@module("@pulumi/kubernetes") @scope(("rbac", "v1")) @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?, unit) => t =
  "ClusterRole"
