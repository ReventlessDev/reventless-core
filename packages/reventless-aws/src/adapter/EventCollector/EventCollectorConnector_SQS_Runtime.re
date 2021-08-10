open Util.SQS_Runtime;
open Util.DynamoDbStream_Runtime;

let handleQueueEvent = (handleEvents, queue, queueEvent, _) => {
  let records = queueEvent##_Records->Belt.Option.getWithDefault([||]);
  let jsons =
    records->Belt.Array.keepMap(record =>
      switch (record##eventSource) {
      | "aws:sqs" => record->parseSqsRecord
      | "aws:dynamodb" => record->parseDynamoDbStreamRecord
      | eventSource =>
        Js.log2(
          "EventCollectorConnector_SQS_Runtime: ignoring record from eventSource:",
          eventSource,
        );
        None;
      }
    );

  handleEvents(. jsons)
  |> Js.Promise.then_(_ =>
       records->Belt.Array.map(record =>
         queue->deleteMessage(record##receiptHandle)
       )
       |> Js.Promise.all
       |> Js.Promise.then_(_ => Js.Promise.resolve())
     );
};
