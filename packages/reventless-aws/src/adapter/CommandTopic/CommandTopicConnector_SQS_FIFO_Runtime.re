let handleEvent = (handleCommands, queue, event, _) => {
  let records = event##_Records;
  let jsons =
    records->Belt.Array.keepMap(record => {
      let commandStr = record##body;
      switch (Js.Json.parseExn(commandStr)) {
      | json => Some(json)
      | exception err =>
        Js.log3(
          "CommandTopicConnector_SQS_FIFO_Runtime.handleEvent: Couldn't parse command:",
          commandStr,
          err,
        );
        None;
      };
    });
  handleCommands(. jsons)
  |> Js.Promise.then_(_ =>
       records->Belt.Array.map(record =>
         queue->Util_SQS_Runtime.deleteMessage(record##receiptHandle)
       )
       |> Js.Promise.all
       |> Js.Promise.then_(_ => Js.Promise.resolve())
     );
};

let publish = queue =>
  (. id, _meta: Reventless.Message.meta, json) =>
    queue->Util_SQS_Runtime.sendFifoMessage(
      ~messageBody=json->Js.Json.stringify,
      ~messageGroupId=id,
    );
