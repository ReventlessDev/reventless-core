/** @pulumi/aws/s3/BucketNotification
  see: https://www.pulumi.com/registry/packages/aws/api-docs/s3/bucketnotification

  Attaches an event notification configuration to an existing bucket, so object
  events (`s3:ObjectCreated:*`, `s3:ObjectRemoved:*`, …) fan out to a Lambda,
  SQS queue, or SNS topic. Unlike the `Bucket.onObjectCreated` magic helper, this
  targets a bucket the stack does not own (created out-of-band / imported); the
  invoke permission for the Lambda principal must be granted separately with a
  `Lambda.Permission`.
*/
type t

/* Each event field is an S3 event string, e.g. "s3:ObjectCreated:*". */
type lambdaFunction = {
  id?: string,
  lambdaFunctionArn: Pulumi.Input.t<string>,
  events: array<string>,
  filterPrefix?: string,
  filterSuffix?: string,
}

type queue = {
  id?: string,
  queueArn: Pulumi.Input.t<string>,
  events: array<string>,
  filterPrefix?: string,
  filterSuffix?: string,
}

type topic = {
  id?: string,
  topicArn: Pulumi.Input.t<string>,
  events: array<string>,
  filterPrefix?: string,
  filterSuffix?: string,
}

type args = {
  bucket: Pulumi.Input.t<string> /* bucket.id */,
  eventbridge?: Pulumi.Input.t<bool>,
  lambdaFunctions?: array<lambdaFunction>,
  queues?: array<queue>,
  topics?: array<topic>,
}

@module("@pulumi/aws") @scope("s3") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "BucketNotification"
