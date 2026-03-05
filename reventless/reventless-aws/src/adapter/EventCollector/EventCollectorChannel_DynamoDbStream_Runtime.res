let handleStreamEvent: (
  ReventlessCore.EventCollector.jsonEventsHandler,
  PulumiAws.DynamoDb.Stream.event,
  _,
) => Effect.t<unit, string, unit> = (handleEvents, streamEvent, _) => {
  let jsons = streamEvent.records->Array.filterMap(record =>
    switch record.eventSource {
    | "aws:dynamodb" =>
      switch record->Util.DynamoDbStream_Runtime.parseDynamoDbStreamRecordEvent {
      | NewImage(_, newImage)
      | NewAndOldImage(_, newImage, _) =>
        Some(newImage)
      | _ => None
      }
    | _eventSource => None
    }
  )

  Stream.fromIterable(jsons)->handleEvents->Effect.map(_ => ())
}
