/** @pulumi/kubernetes batch/v1 CronJob
  see: https://www.pulumi.com/registry/packages/kubernetes/api-docs/batch/v1/cronjob/
*/

/** The Job embedded in a CronJob — metadata plus a Job spec. */
type jobTemplateSpec = {
  metadata?: Meta.objectMeta,
  spec: Batch_Job.jobSpec,
}

type cronJobSpec = {
  schedule: string,
  jobTemplate: jobTemplateSpec,
  concurrencyPolicy?: string,
  suspend?: bool,
  startingDeadlineSeconds?: int,
  successfulJobsHistoryLimit?: int,
  failedJobsHistoryLimit?: int,
  timeZone?: string,
}

type t = {
  id: Pulumi.Output.t<string>,
  apiVersion: Pulumi.Output.t<string>,
  kind: Pulumi.Output.t<string>,
  metadata: Pulumi.Output.t<Meta.objectMeta>,
  spec: Pulumi.Output.t<cronJobSpec>,
}

type args = {
  metadata?: Pulumi.Input.t<Meta.objectMeta>,
  spec?: Pulumi.Input.t<cronJobSpec>,
}

@module("@pulumi/kubernetes") @scope(("batch", "v1")) @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?, unit) => t =
  "CronJob"
