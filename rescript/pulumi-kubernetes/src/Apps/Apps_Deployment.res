/** @pulumi/kubernetes apps/v1 Deployment
  see: https://www.pulumi.com/registry/packages/kubernetes/api-docs/apps/v1/deployment/
*/

/** `maxSurge` / `maxUnavailable` are int-or-string; pass `JSON.Number(1)` or
  `JSON.String("25%")`. */
type rollingUpdateDeployment = {
  maxSurge?: JSON.t,
  maxUnavailable?: JSON.t,
}

type deploymentStrategy = {
  @as("type") type_?: string,
  rollingUpdate?: rollingUpdateDeployment,
}

type deploymentSpec = {
  selector: Meta.labelSelector,
  template: Core_Pod.podTemplateSpec,
  replicas?: int,
  strategy?: deploymentStrategy,
  minReadySeconds?: int,
  revisionHistoryLimit?: int,
  progressDeadlineSeconds?: int,
  paused?: bool,
}

type t = {
  id: Pulumi.Output.t<string>,
  apiVersion: Pulumi.Output.t<string>,
  kind: Pulumi.Output.t<string>,
  metadata: Pulumi.Output.t<Meta.objectMeta>,
  spec: Pulumi.Output.t<deploymentSpec>,
}

type args = {
  metadata?: Pulumi.Input.t<Meta.objectMeta>,
  spec?: Pulumi.Input.t<deploymentSpec>,
}

@module("@pulumi/kubernetes") @scope(("apps", "v1")) @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?, unit) => t =
  "Deployment"
