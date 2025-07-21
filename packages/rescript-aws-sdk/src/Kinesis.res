/***  aws-sdk/Kinesis
    see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/kinesis/
*/
type client

module Raw = {
  @module("@aws-sdk/client-kinesis") @new
  external client: unit => client = "KinesisClient"
}

let clientInstance = ref(None)

/** create a CloudWatchEventsClient with no default values
  use `Raw.client` if you want to set alternative configuration
*/
let client = () =>
  switch clientInstance.contents {
  | None =>
    let client = Raw.client()
    clientInstance := Some(client)
    client
  | Some(client) => client
  }

module PutRecordCommand = {
  type input = {
    @as("Data") data: string,
    @as("StreamName") streamName: string,
    @as("PartitionKey") partitionKey: string,
    @as("ExplicitHashKey") explicitHashKey?: string,
    @as("SequenceNumberForOrdering") sequenceNumberForOrdering?: string,
  }

  type output = {
    @as("ShardId") shardId: string,
    @as("SequenceNumber") sequenceNumber?: string,
    @as("EncryptionType") encryptionType: option<string>,
  }

  type t
  @new @module("@aws-sdk/client-kinesis")
  external make: input => t = "PutRecordCommand"

  module Raw = {
    @send
    external send: (client, t) => Js.Promise.t<output> = "send"
  }

  let send: t => Js.Promise.t<output> = command => Raw.send(client(), command)
}
