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

let parseDynamoDbStreamRecord = (buildJson, record: Record.t) => {
  let record = record["dynamodb"]
  let id =
    record->Belt.Option.flatMap(record =>
      AwsSdk.DynamoDb.Converter.output(~data=record["_Keys"]["id"], ())
    )

  let newImageJson =
    record
    ->Belt.Option.flatMap(dynamodb => dynamodb["_NewImage"])
    ->Belt.Option.map(newImage => AwsSdk.DynamoDb.Converter.unmarshall(~data=newImage, ()))
    ->Belt.Option.map(buildJson)

  let oldImageJson =
    record
    ->Belt.Option.flatMap(dynamodb => dynamodb["_OldImage"])
    ->Belt.Option.map(oldImage => AwsSdk.DynamoDb.Converter.unmarshall(~data=oldImage, ()))
    ->Belt.Option.map(buildJson)

  switch (id, newImageJson, oldImageJson) {
  | (Some(id), Some(newImage), Some(oldImage)) => NewAndOldImage(id, newImage, oldImage)
  | (Some(id), Some(newImage), None) => NewImage(id, newImage)
  | (Some(id), None, Some(oldImage)) => OldImage(id, oldImage)
  | _ => Invalid
  }
}

let parseDynamoDbStreamRecordEvent: Record.t => result = record =>
  parseDynamoDbStreamRecord(buildEvent'Json, record)

let parseDynamoDbStreamRecordState: Record.t => result = record =>
  parseDynamoDbStreamRecord(buildStateJson, record)

let findResource = resources => resources->Reventless.Util.AdapterRuntime.findResource(service)
