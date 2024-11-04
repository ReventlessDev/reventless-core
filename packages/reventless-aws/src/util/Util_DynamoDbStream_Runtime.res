open AwsSdk.DynamoDb.Stream

let service = "DynamoDbStream"

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

let parseDynamoDbStreamRecord = (buildJson, record: AwsSdk.DynamoDb.Stream.Record.t) => {
  let dynamoDb = record["dynamodb"]
  let id =
    dynamoDb->Belt.Option.flatMap(dynamoDb =>
      AwsSdk.DynamoDb.Converter.output(~data=dynamoDb["_Keys"]["id"], ())
    )

  let newImageJson =
    dynamoDb
    ->Belt.Option.flatMap(dynamoDb => dynamoDb["_NewImage"])
    ->Belt.Option.map(newImage => AwsSdk.DynamoDb.Converter.unmarshall(~data=newImage, ()))
    ->Belt.Option.map(buildJson)

  let oldImageJson =
    dynamoDb
    ->Belt.Option.flatMap(dynamoDb => dynamoDb["_OldImage"])
    ->Belt.Option.map(oldImage => AwsSdk.DynamoDb.Converter.unmarshall(~data=oldImage, ()))
    ->Belt.Option.map(buildJson)

  switch (id, newImageJson, oldImageJson) {
  | (Some(id), Some(newImage), Some(oldImage)) => NewAndOldImage(id, newImage, oldImage)
  | (Some(id), Some(newImage), None) => NewImage(id, newImage)
  | (Some(id), None, Some(oldImage)) => OldImage(id, oldImage)
  | _ => Invalid
  }
}

let parseDynamoDbStreamRecordEvent: AwsSdk.DynamoDb.Stream.Record.t => result = record =>
  parseDynamoDbStreamRecord(buildEvent'Json, record)

let parseDynamoDbStreamRecordState: AwsSdk.DynamoDb.Stream.Record.t => result = record =>
  parseDynamoDbStreamRecord(buildStateJson, record)

let findResource = resources => resources->Reventless.Util.AdapterRuntime.findResource(service)
