/** @pulumi/aws/lambda/eventsourcemapping
  see: https://www.pulumi.com/registry/packages/aws/api-docs/lambda/eventsourcemapping/
 */
type onFailure = {destinationArn: Pulumi.Input.t<string>}

type destinationConfig = {onFailure: onFailure}

type functionResponseType = ReportBatchItemFailures

type startingPosition = AT_TIMESTAMP | LATEST | TRIM_HORIZON

/** construct an eventSourceMappingsArgs object
   
    functionName: The name or the ARN of the Lambda function that will be subscribing to events.
   
    batchSize: The largest number of records that Lambda will retrieve from your event source at the time of invocation.
    Defaults to 100 for DynamoDB, Kinesis, MQ and MSK, 10 for SQS.
   
    bisectBatchOnFunctionError: If the function returns an error, split the batch in two and retry.
    Only available for stream sources (DynamoDB and Kinesis). Defaults to false.
   
    enabled: Determines if the mapping will be enabled on creation. Defaults to true.
   
    eventSourceArn: The event source ARN - this is required for Kinesis stream, DynamoDB stream, SQS queue, MQ broker or MSK cluster.
    It is incompatible with a Self Managed Kafka source.
   
    functionResponseTypes: A list of current response type enums applied to the event source mapping for AWS Lambda checkpointing.
    Only available for stream sources (DynamoDB and Kinesis). Valid values: ReportBatchItemFailures.
   
    maximumBatchingWindowInSeconds: The maximum amount of time to gather records before invoking the function, in seconds (between 0 and 300).
    Records will continue to buffer (or accumulate in the case of an SQS queue event source) until either maximumBatchingWindowInSeconds expires or batchSize has been met.
   
    maximumRecordAgeInSeconds: The maximum age of a record that Lambda sends to a function for processing.
    Only available for stream sources (DynamoDB and Kinesis). Must be either -1 (forever, and the default value) or between 60 and 604800 (inclusive).
   
    maximumRetryAttempts: The maximum number of times to retry when the function returns an error.
    Only available for stream sources (DynamoDB and Kinesis). Minimum and default of -1 (forever), maximum of 10000.
   
    parallelizationFactor: The number of batches to process from each shard concurrently.
    Only available for stream sources (DynamoDB and Kinesis). Minimum and default of 1, maximum of 10.
   
    startingPosition: The position in the stream where AWS Lambda should start reading.
    Must be one of AT_TIMESTAMP (Kinesis only), LATEST or TRIM_HORIZON if getting events from Kinesis, DynamoDB or MSK. Must not be provided if getting events from SQS.
   
    startingPositionTimestamp: A timestamp in RFC3339 format of the data record which to start reading when using starting_position set to AT_TIMESTAMP.
    If a record with this exact timestamp does not exist, the next later record is chosen.
    If the timestamp is older than the current trim horizon, the oldest available record is chosen.
   
    tumblingWindowInSeconds: The duration in seconds of a processing window for AWS Lambda streaming analytics.
    The range is between 1 second up to 900 seconds. Only available for stream sources (DynamoDB and Kinesis).
   */
type args = {
  functionName: Pulumi.Input.t<string>,
  batchSize?: int,
  bisectBatchOnFunctionError?: bool,
  destinationConfig?: destinationConfig,
  enabled?: bool,
  eventSourceArn?: Pulumi.Input.t<string>,
  functionResponseTypes?: array<functionResponseType>,
  maximumBatchingWindowInSeconds?: int,
  maximumRecordAgeInSeconds?: int,
  maximumRetryAttempts?: int,
  parallelizationFactor?: int,
  startingPosition?: startingPosition,
  startingPositionTimestamp?: Pulumi.Input.t<string>,
  tumblingWindowInSeconds?: int,
  tags?: Pulumi.Input.t<Aws.tags>,
}

type t = {
  id: Pulumi.Output.t<string>,
  arn: Pulumi.Output.t<string>,
  batchSize: Pulumi.Output.t<int>,
  enabled: Pulumi.Output.t<bool>,
}

@module("@pulumi/aws") @scope("lambda") @new
external make: (~name: string, ~args: args, ~opts: option<Pulumi.CustomResourceOptions.t>) => t =
  "EventSourceMapping"
