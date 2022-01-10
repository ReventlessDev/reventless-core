open Reventless.Message;
open AwsSdk;

let sendMessage = (queue: PulumiAws.SQS.Queue.t, ~delay=?, messageBody) =>
  SQS.sendMessage(
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
  SQS.sendMessage(
    ~queueId=queue##id->Pulumi.Output.get,
    ~messageBody,
    ~messageGroupId,
    ~delay?,
    (),
  );

let makeEntry =
    (queueService, commandId, {msgId} as meta, commandJson, delay) => {
  let commandMeta: meta = {...meta, msgId: uuid(), time: nowAsISOString()};
  let json =
    [|
      ("id", commandId->Js.Json.string),
      ("meta", commandMeta->Reventless.Message.meta_encode),
      ("command", commandJson),
    |]
    ->Js.Dict.fromArray
    ->Js.Json.object_;
  let messageBody = json->Js.Json.stringify;
  let target = meta.service;
  Js.log(
    {j|Publishing command to Aggregate $target: $messageBody id: $commandId|j},
  );
  if (queueService == Util_SQS_FIFO.service) {
    SQS.makeBatchEntryFifo(
      ~groupId=commandId,
      ~messageId=msgId,
      ~messageBody,
      ~delay,
    );
  } else {
    SQS.makeBatchEntry(~messageId=msgId, ~messageBody, ~delay);
  };
};

let sendBatch = (queue, queueService, commandJsons) =>
  commandJsons
  ->Belt.Array.map(({id, meta, commandJson, delay}) =>
      makeEntry(queueService, id, meta, commandJson, delay)
    )
  ->SQS.sendMessageBatch(~queueId=queue##id->Pulumi.Output.get)
  ->Reventless.Util.Promise.allSettled
  |> Js.Promise.then_(results => {
       results
       ->Reventless.Util.Promise.filterRejected
       ->Belt.Array.forEach(((idx, reason)) =>
           Js.log({j|SQS.sendMessageBatch request $idx failed: $reason|j})
         );
       Js.Promise.resolve(); // TODO: error handling
     });

let deleteMessage = (queue, receiptHandle) =>
  SQS.deleteMessage(~queueId=queue##id->Pulumi.Output.get, ~receiptHandle);

let deleteMessageBatch = (queue, entries) =>
  SQS.deleteMessageBatch(~queueId=queue##id->Pulumi.Output.get, entries);

let parseSqsRecord = record => {
  let eventStr = record##body;
  switch (eventStr->Js.Json.parseExn) {
  | json => Some(json)
  | exception err =>
    Js.log3("parseSqsRecord: Couldn't parse event:", eventStr, err);
    None;
  };
};
