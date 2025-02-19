let handleStreamEvent: (
  array<Js.Json.t> => promise<unit>,
  PulumiAws.DynamoDb.Stream.event,
  _,
) => Js.Promise.t<unit> = async (handleEvents, streamEvent, _) => {
  let jsons = streamEvent.records->Belt.Array.keepMap(record =>
    switch record.eventSource {
    | "aws:dynamodb" =>
      switch record->Util.DynamoDbStream_Runtime.parseDynamoDbStreamRecordEvent {
      | NewImage(_, newImage)
      | NewAndOldImage(_, newImage, _) =>
        Some(newImage)
      | _ =>
        Js.log(__MODULE__ ++ ": no NewImage included in Stream event !")
        None
      }
    | eventSource =>
      Js.log2(__MODULE__ ++ ": ignoring record from eventSource:", eventSource)
      None
    }
  )

  try await handleEvents(jsons) catch {
  | err =>
    //  Js.Exn.raiseError(err->Reventless.Util.Error.ofPromise##message)
    Js.log2("handleStreamEvent error:", err)
  }
}
