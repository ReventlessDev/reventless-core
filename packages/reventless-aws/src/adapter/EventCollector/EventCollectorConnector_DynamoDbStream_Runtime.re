let handleStreamEvent = (handleEvents, streamEvent, _) => {
  let records = streamEvent##_Records->Belt.Option.getWithDefault([||]);
  let jsons =
    records->Belt.Array.keepMap(record =>
      switch (record##eventSource) {
      | "aws:dynamodb" =>
        switch (
          record->Util.DynamoDbStream_Runtime.parseDynamoDbStreamRecordEvent
        ) {
        | NewImage(_, newImage)
        | NewAndOldImage(_, newImage, _) => Some(newImage)
        | _ =>
          Js.log(__MODULE__ ++ ": no NewImage included in Stream event !");
          None;
        }
      | eventSource =>
        Js.log2(
          __MODULE__ ++ ": ignoring record from eventSource:",
          eventSource,
        );
        None;
      }
    );

  handleEvents(. jsons)
  |> Js.Promise.catch(err =>
       Js.Exn.raiseError(err->AwsSdk.Error.ofPromise##message)
     );
};
