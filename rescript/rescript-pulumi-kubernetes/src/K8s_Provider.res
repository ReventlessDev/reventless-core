/** @pulumi/kubernetes Provider — cluster connection.
  see: https://www.pulumi.com/registry/packages/kubernetes/api-docs/provider/
*/

/** A Kubernetes Provider is a Pulumi ProviderResource; pass the value straight
  into `Pulumi.CustomResourceOptions.t.provider` via `asProviderResource`. */
type t = Pulumi.ProviderResource.t

type args = {
  /** Raw kubeconfig contents (or a path). */
  kubeconfig?: Pulumi.Input.t<string>,
  /** Name of the kubeconfig context to use. */
  context?: Pulumi.Input.t<string>,
  /** Name of the kubeconfig cluster to use. */
  cluster?: Pulumi.Input.t<string>,
  /** Default namespace for namespaced resources. */
  namespace?: Pulumi.Input.t<string>,
  /** Opt every resource into server-side apply. */
  enableServerSideApply?: Pulumi.Input.t<bool>,
  /** Allow ConfigMaps to be patched in place rather than replaced. */
  enableConfigMapMutable?: Pulumi.Input.t<bool>,
  suppressDeprecationWarnings?: Pulumi.Input.t<bool>,
  suppressHelmHookWarnings?: Pulumi.Input.t<bool>,
  /** Delete resources from state when the cluster is unreachable. */
  deleteUnreachable?: Pulumi.Input.t<bool>,
  skipUpdateUnreachable?: Pulumi.Input.t<bool>,
}

@module("@pulumi/kubernetes") @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?, unit) => t =
  "Provider"

external asProviderResource: t => Pulumi.ProviderResource.t = "%identity"
