let putRecord = (stream, ~data) =>
  AwsSdk.Kinesis.putRecord(
    AwsSdk.Kinesis.kinesis(),
    ~streamName=stream##name->Pulumi.Output.get,
    ~partitionKey="",
    ~data,
  ) /* TODO partitionKe*/;