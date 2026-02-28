let handleStreamEvent: (
  ReventlessCore.EventCollector.jsonEventsHandler,
  PulumiAws.DynamoDb.Stream.event,
  _,
) => promise<unit> = async (handleEvents, streamEvent, _) => {
  let jsons = streamEvent.records->Array.filterMap(record =>
    switch record.eventSource {
    | "aws:dynamodb" =>
      switch record->Util.DynamoDbStream_Runtime.parseDynamoDbStreamRecordEvent {
      | NewImage(_, newImage)
      | NewAndOldImage(_, newImage, _) =>
        Some(newImage)
      | _ =>
        Console.log(__MODULE__ ++ ": no NewImage included in Stream event !")
        None
      }
    | eventSource =>
      Console.log2(__MODULE__ ++ ": ignoring record from eventSource:", eventSource)
      None
    }
  )

  try await (Stream.fromIterable(jsons)->handleEvents->Effect.runPromise) catch {
  | err => Console.log2("handleStreamEvent error:", err)
  }
}
