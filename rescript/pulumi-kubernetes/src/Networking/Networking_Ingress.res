/** @pulumi/kubernetes networking.k8s.io/v1 Ingress
  see: https://www.pulumi.com/registry/packages/kubernetes/api-docs/networking/v1/ingress/
*/
type ingressServiceBackendPort = {number?: int, name?: string}
type ingressServiceBackend = {name: string, port?: ingressServiceBackendPort}
type ingressBackend = {
  service?: ingressServiceBackend,
  /** TypedLocalObjectReference for non-Service backends; kept opaque. */
  resource?: JSON.t,
}

type httpIngressPath = {
  /** One of `"Exact"`, `"Prefix"`, `"ImplementationSpecific"`. */
  pathType: string,
  backend: ingressBackend,
  path?: string,
}
type httpIngressRuleValue = {paths: array<httpIngressPath>}
type ingressRule = {host?: string, http?: httpIngressRuleValue}
type ingressTLS = {hosts?: array<string>, secretName?: string}

type ingressSpec = {
  ingressClassName?: string,
  defaultBackend?: ingressBackend,
  rules?: array<ingressRule>,
  tls?: array<ingressTLS>,
}

type t = {
  id: Pulumi.Output.t<string>,
  apiVersion: Pulumi.Output.t<string>,
  kind: Pulumi.Output.t<string>,
  metadata: Pulumi.Output.t<Meta.objectMeta>,
  spec: Pulumi.Output.t<ingressSpec>,
}

type args = {
  metadata?: Pulumi.Input.t<Meta.objectMeta>,
  spec?: Pulumi.Input.t<ingressSpec>,
}

@module("@pulumi/kubernetes") @scope(("networking", "v1")) @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?, unit) => t =
  "Ingress"
