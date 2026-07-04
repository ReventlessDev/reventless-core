/** @pulumi/kubernetes core/v1 Service
  see: https://www.pulumi.com/registry/packages/kubernetes/api-docs/core/v1/service/
*/

/** `targetPort` is int-or-string in the API; pass `JSON.Number(...)` for a port
  number or `JSON.String(...)` for a named container port. */
type servicePort = {
  port: int,
  targetPort?: JSON.t,
  protocol?: string,
  name?: string,
  nodePort?: int,
}

type serviceSpec = {
  @as("type") type_?: string,
  selector?: dict<string>,
  ports?: array<servicePort>,
  clusterIP?: string,
  externalName?: string,
  loadBalancerClass?: string,
  sessionAffinity?: string,
  publishNotReadyAddresses?: bool,
}

type loadBalancerIngress = {ip?: string, hostname?: string}
type loadBalancerStatus = {ingress?: array<loadBalancerIngress>}
type serviceStatus = {loadBalancer?: loadBalancerStatus}

type t = {
  id: Pulumi.Output.t<string>,
  apiVersion: Pulumi.Output.t<string>,
  kind: Pulumi.Output.t<string>,
  metadata: Pulumi.Output.t<Meta.objectMeta>,
  spec: Pulumi.Output.t<serviceSpec>,
  status: Pulumi.Output.t<serviceStatus>,
}

type args = {
  metadata?: Pulumi.Input.t<Meta.objectMeta>,
  spec?: Pulumi.Input.t<serviceSpec>,
}

@module("@pulumi/kubernetes") @scope(("core", "v1")) @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?, unit) => t =
  "Service"
