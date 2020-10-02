let append = table =>
  (. _sequenceNr, _id, jsons) =>
    jsons
    |> table##name
       ->Pulumi.Output.get
       ->AwsSdk.DynamoDb.DocumentClient.batchWrite(
           "attribute_not_exists (sequenceNr)",
         );

let replay = table =>
  (. id) =>
    table##name
    ->Pulumi.Output.get
    ->AwsSdk.DynamoDb.DocumentClient.queryByIdWithTableName(id);