/** @pulumi/kubernetes helm/v3 Release — an imperative `helm install`.
  see: https://www.pulumi.com/registry/packages/kubernetes/api-docs/helm/v3/release/

  v3 `Release` (stable, imperative-install semantics) is bound; the v4
  `helm/v4.Chart` API is deliberately left for a later addition once it settles.
*/
type repositoryOpts = {
  /** Chart repository URL, e.g. `"https://charts.bitnami.com/bitnami"`. */
  repo?: string,
  username?: string,
  password?: string,
}

type t = {
  id: Pulumi.Output.t<string>,
  name: Pulumi.Output.t<string>,
  namespace: Pulumi.Output.t<string>,
  status: Pulumi.Output.t<JSON.t>,
}

type args = {
  /** Chart name (repo chart) or a local path. */
  chart: Pulumi.Input.t<string>,
  version?: Pulumi.Input.t<string>,
  /** Release name; defaults to the resource name when omitted. */
  name?: Pulumi.Input.t<string>,
  namespace?: Pulumi.Input.t<string>,
  createNamespace?: Pulumi.Input.t<bool>,
  repositoryOpts?: Pulumi.Input.t<repositoryOpts>,
  /** Chart values, as a JSON object matching the chart's `values.yaml`. */
  values?: Pulumi.Input.t<JSON.t>,
  skipAwait?: Pulumi.Input.t<bool>,
  atomic?: Pulumi.Input.t<bool>,
  cleanupOnFail?: Pulumi.Input.t<bool>,
  forceUpdate?: Pulumi.Input.t<bool>,
  waitForJobs?: Pulumi.Input.t<bool>,
  maxHistory?: Pulumi.Input.t<int>,
  timeout?: Pulumi.Input.t<int>,
}

@module("@pulumi/kubernetes") @scope(("helm", "v3")) @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?, unit) => t =
  "Release"
