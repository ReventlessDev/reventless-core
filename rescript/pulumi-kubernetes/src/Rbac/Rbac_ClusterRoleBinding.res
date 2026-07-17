/** @pulumi/kubernetes rbac.authorization.k8s.io/v1 ClusterRoleBinding
  see: https://www.pulumi.com/registry/packages/kubernetes/api-docs/rbac/v1/clusterrolebinding/
*/
type t = {
  id: Pulumi.Output.t<string>,
  apiVersion: Pulumi.Output.t<string>,
  kind: Pulumi.Output.t<string>,
  metadata: Pulumi.Output.t<Meta.objectMeta>,
}

type args = {
  metadata?: Pulumi.Input.t<Meta.objectMeta>,
  roleRef: Pulumi.Input.t<Rbac_RoleBinding.roleRef>,
  subjects?: Pulumi.Input.t<array<Rbac_RoleBinding.subject>>,
}

@module("@pulumi/kubernetes") @scope(("rbac", "v1")) @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?, unit) => t =
  "ClusterRoleBinding"
