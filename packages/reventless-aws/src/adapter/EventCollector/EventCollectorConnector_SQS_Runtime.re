let handleQueueEvent = (handleEvents, queue, queueEvent, _) => {
  let records = queueEvent##_Records;
  let jsons =
    records->Belt.Array.keepMap(record => {
      let eventStr = record##body;
      switch (Js.Json.parseExn(eventStr)) {
      | json => Some(json)
      | exception err =>
        Js.log3(
          "EventCollectorConnector_SQS.handleQueueEvent: Couldn't parse command:",
          eventStr,
          err,
        );
        None;
      };
    });

  handleEvents(. jsons)
  |> Js.Promise.then_(_ =>
       records->Belt.Array.map(record =>
         queue->Util_SQS_Runtime.deleteMessage(
           record##receiptHandle,
         )
       )
       |> Js.Promise.all
       |> Js.Promise.then_(_ => Js.Promise.resolve())
     );
};