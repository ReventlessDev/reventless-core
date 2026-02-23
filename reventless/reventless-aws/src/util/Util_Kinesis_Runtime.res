let putRecord = (stream, ~data) =>
  AwsSdk.Kinesis.PutRecordCommand.make({
    data,
    //FIXME: remove JST after merge of rescript-v11 upgrade
    streamName: stream["name"]->Pulumi.Output.get,
    partitionKey: "",
  })->AwsSdk.Kinesis.PutRecordCommand.send
/* TODO partitionKey */
