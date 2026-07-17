/** @pulumi/kubernetes networking.k8s.io/v1 NetworkPolicy
  see: https://www.pulumi.com/registry/packages/kubernetes/api-docs/networking/v1/networkpolicy/
*/

/** `port` is int-or-string; pass `JSON.Number(...)` or `JSON.String("http")`. */
type networkPolicyPort = {
  port?: JSON.t,
  protocol?: string,
  endPort?: int,
}

type ipBlock = {cidr: string, except?: array<string>}

type networkPolicyPeer = {
  podSelector?: Meta.labelSelector,
  namespaceSelector?: Meta.labelSelector,
  ipBlock?: ipBlock,
}

type networkPolicyIngressRule = {
  ports?: array<networkPolicyPort>,
  from?: array<networkPolicyPeer>,
}

type networkPolicyEgressRule = {
  ports?: array<networkPolicyPort>,
  @as("to") to_?: array<networkPolicyPeer>,
}

type networkPolicySpec = {
  podSelector: Meta.labelSelector,
  policyTypes?: array<string>,
  ingress?: array<networkPolicyIngressRule>,
  egress?: array<networkPolicyEgressRule>,
}

type t = {
  id: Pulumi.Output.t<string>,
  apiVersion: Pulumi.Output.t<string>,
  kind: Pulumi.Output.t<string>,
  metadata: Pulumi.Output.t<Meta.objectMeta>,
  spec: Pulumi.Output.t<networkPolicySpec>,
}

type args = {
  metadata?: Pulumi.Input.t<Meta.objectMeta>,
  spec?: Pulumi.Input.t<networkPolicySpec>,
}

@module("@pulumi/kubernetes") @scope(("networking", "v1")) @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?, unit) => t =
  "NetworkPolicy"
