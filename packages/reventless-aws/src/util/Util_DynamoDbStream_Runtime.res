type result =
  | NewImage(string, Js.Json.t)
  | OldImage(string, Js.Json.t)
  | NewAndOldImage(string, Js.Json.t, Js.Json.t)
  | Invalid

let buildEvent'Json = dict =>
  [
    ("id", dict->Js.Dict.get("id")->Belt.Option.getExn),
    ("meta", dict->Reventless.Message.composeMeta),
    ("event", dict->Js.Dict.get("event")->Belt.Option.getExn),
  ]
  ->Js.Dict.fromArray
  ->Js.Json.object_

let buildStateJson = dict => dict->Js.Json.object_

let parseDynamoDbStreamRecord = (buildJson, record: PulumiAws.DynamoDb.Stream.record) => {
  let record = record.dynamodb
  let id = record->Belt.Option.flatMap(record => AwsSdk.DynamoDb.Util.unmarshall(record.keys.id))

  let newImageJson =
    record
    ->Belt.Option.flatMap(dynamodb => dynamodb.newImage)
    ->Option.map(newImage => AwsSdk.DynamoDb.Util.unmarshallDict(newImage))
    ->Option.map(buildJson)

  let oldImageJson =
    record
    ->Belt.Option.flatMap(dynamodb => dynamodb.oldImage)
    ->Option.map(oldImage => AwsSdk.DynamoDb.Util.unmarshallDict(oldImage))
    ->Option.map(buildJson)

  switch (id, newImageJson, oldImageJson) {
  | (Some(id), Some(newImage), Some(oldImage)) => NewAndOldImage(id, newImage, oldImage)
  | (Some(id), Some(newImage), None) => NewImage(id, newImage)
  | (Some(id), None, Some(oldImage)) => OldImage(id, oldImage)
  | _ => Invalid
  }
}

let parseDynamoDbStreamRecordEvent: PulumiAws.DynamoDb.Stream.record => result = record =>
  parseDynamoDbStreamRecord(buildEvent'Json, record)

let parseDynamoDbStreamRecordState: PulumiAws.DynamoDb.Stream.record => result = record =>
  parseDynamoDbStreamRecord(buildStateJson, record)

let findResource = resources =>
  resources->Reventless.Util.AdapterRuntime.findResource(AWS.DynamoDbStream.service)
