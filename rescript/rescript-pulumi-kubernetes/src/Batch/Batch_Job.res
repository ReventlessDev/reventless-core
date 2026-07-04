/** @pulumi/kubernetes batch/v1 Job
  see: https://www.pulumi.com/registry/packages/kubernetes/api-docs/batch/v1/job/
*/
type jobSpec = {
  template: Core_Pod.podTemplateSpec,
  backoffLimit?: int,
  completions?: int,
  parallelism?: int,
  activeDeadlineSeconds?: int,
  ttlSecondsAfterFinished?: int,
  completionMode?: string,
  suspend?: bool,
  selector?: Meta.labelSelector,
  manualSelector?: bool,
}

type t = {
  id: Pulumi.Output.t<string>,
  apiVersion: Pulumi.Output.t<string>,
  kind: Pulumi.Output.t<string>,
  metadata: Pulumi.Output.t<Meta.objectMeta>,
  spec: Pulumi.Output.t<jobSpec>,
}

type args = {
  metadata?: Pulumi.Input.t<Meta.objectMeta>,
  spec?: Pulumi.Input.t<jobSpec>,
}

@module("@pulumi/kubernetes") @scope(("batch", "v1")) @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?, unit) => t = "Job"
