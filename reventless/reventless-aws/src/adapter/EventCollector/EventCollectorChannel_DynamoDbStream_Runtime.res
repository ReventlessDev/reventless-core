// Shared record decoder for the ReadModel / StateViewSlice entry points.
//
// DynamoDB path: the Lambda is invoked by DynamoDB-stream ESMs — decode each
// NEW_IMAGE. Postgres path (B3.0): the Lambda is invoked by its SQS feed queue,
// fed by the PgChangeFeedRelay with ready-made `{id, meta, event}` bodies —
// parse each body straight back to JSON. Both record kinds can appear in one
// deployment (mixed backends), so the branch is per record, not per event.
let handleStreamEvent: (
  ReventlessCore.EventCollector.jsonEventsHandler,
  PulumiAws.Lambda.CallbackFunction.event,
  _,
) => Effect.t<unit, string, unit> = (handleEvents, event, _) => {
  let jsons = event.records->Array.filterMap(record =>
    switch record.eventSource {
    | "aws:sqs" => record->PulumiAws.SQS.Queue.asRecord->Util.SQS_Runtime.parseSqsRecord
    | "aws:dynamodb" =>
      switch record
      ->PulumiAws.DynamoDb.Stream.asRecord
      ->Util.DynamoDbStream_Runtime.parseDynamoDbStreamRecordEvent {
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
