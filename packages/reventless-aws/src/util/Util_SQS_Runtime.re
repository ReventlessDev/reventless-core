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
    (queue: PulumiAws.SQS.Queue.t, ~delay=?, ~messageGroupId, messageBody) =>
  SQS.sendMessage(
    ~queueId=queue##id->Pulumi.Output.get,
    ~messageBody,
    ~messageGroupId,
    ~delay?,
    (),
  );

let toMessageBody = ({id, meta, commandJson}) => {
  let commandMeta: meta = {...meta, msgId: uuid(), time: nowAsISOString()};
  [|
    ("id", id->Js.Json.string),
    ("meta", commandMeta->Reventless.Message.meta_encode),
    ("command", commandJson),
  |]
  ->Js.Dict.fromArray
  ->Js.Json.object_
  ->Js.Json.stringify;
};

let send = (queue, queueService, {id, delay} as commandJson) => {
  let messageBody = commandJson->toMessageBody;
  if (queueService == Util_SQS_FIFO.service) {
    queue->sendFifoMessage(~messageGroupId=id, ~delay?, messageBody);
  } else {
    queue->sendMessage(~delay?, messageBody);
  };
};

let makeEntry =
    (
      queueService,
      {id, meta: {msgId: messageId, service}, delay} as commandJson,
    ) => {
  let messageBody = commandJson->toMessageBody;
  Js.log(
    {j|Publishing command to Aggregate $service: $messageBody id: $id|j},
  );
  if (queueService == Util_SQS_FIFO.service) {
    SQS.makeBatchEntryFifo(~groupId=id, ~messageId, ~messageBody, ~delay);
  } else {
    SQS.makeBatchEntry(~messageId, ~messageBody, ~delay);
  };
};

let sendBatch = (queue, queueService, commandJsons) =>
  commandJsons
  ->Belt.Array.map(commandJson => makeEntry(queueService, commandJson))
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
