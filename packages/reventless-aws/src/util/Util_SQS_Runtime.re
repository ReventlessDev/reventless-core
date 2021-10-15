let sendMessage = (queue: PulumiAws.SQS.Queue.t, ~delay=?, messageBody) =>
  AwsSdk.SQS.sendMessage(
    ~queueId=queue##id->Pulumi.Output.get,
    ~messageBody,
    ~delay?,
    (),
  );

let sendFifoMessage =
    (
      queue: PulumiAws.SQS.Queue.t,
      ~delay=?,
      ~messageBody,
      ~messageGroupId,
      (),
    ) =>
  AwsSdk.SQS.sendMessage(
    ~queueId=queue##id->Pulumi.Output.get,
    ~messageBody,
    ~messageGroupId,
    ~delay?,
    (),
  );

let deleteMessage = (queue: PulumiAws.SQS.Queue.t, receiptHandle) =>
  AwsSdk.SQS.deleteMessage(
    ~queueId=queue##id->Pulumi.Output.get,
    ~receiptHandle,
  );

let deleteMessageBatch = (queue: PulumiAws.SQS.Queue.t, entries) =>
  AwsSdk.SQS.deleteMessageBatch(
    ~queueId=queue##id->Pulumi.Output.get,
    entries,
  );

let parseSqsRecord = record => {
  let eventStr = record##body;
  switch (eventStr->Js.Json.parseExn) {
  | json => Some(json)
  | exception err =>
    Js.log3("parseSqsRecord: Couldn't parse event:", eventStr, err);
    None;
  };
};
