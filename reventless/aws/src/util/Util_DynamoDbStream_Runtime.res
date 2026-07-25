type result =
  | NewImage(string, JSON.t)
  | OldImage(string, JSON.t)
  | NewAndOldImage(string, JSON.t, JSON.t)
  | Invalid

// Returns None for rows that aren't events — e.g. DCB FENCE rows and aggregate
// snapshot rows (position = "SNAPSHOT"; docs/plans/aggregate-snapshotting.md),
// neither of which has an `event` column. The caller filters these out via
// `Invalid` rather than synthesising a bogus event that sury would later reject.
let buildJsonEvent' = dict => {
  switch (dict->Dict.get("event"), dict->Dict.get("data")) {
  | (Some(JSON.String(eventType)), data) =>
    let payload = switch data {
    | Some(JSON.Object(d)) => d
    | _ => Dict.make()
    }
    // DCB events lack meta fields (service, time, msgId) — synthesise a minimal
    // meta so composeMeta doesn't crash on Option.getOrThrow.
    let hasMeta = dict->Dict.get("service")->Option.isSome
    let meta = if hasMeta {
      dict->ReventlessCore.Message.composeMeta
    } else {
      let position =
        dict->Dict.get("position")->Option.flatMap(JSON.Decode.string)->Option.getOr("")
      [
        ("service", ""->JSON.Encode.string),
        ("time", position->JSON.Encode.string),
        ("ip", ""->JSON.Encode.string),
        ("user", ""->JSON.Encode.string),
        ("msgId", position->JSON.Encode.string),
        ("correlationId", position->JSON.Encode.string),
      ]
      ->Dict.fromArray
      ->JSON.Encode.object
    }
    // Carry the stored `recorded_at` column into the envelope so StateViewSlice
    // projections receive it as `consumed.recordedAt` (the authoritative storage
    // time on the AWS path). Absent on non-event rows → empty string.
    let recordedAt =
      dict->Dict.get("recordedAt")->Option.getOr(""->JSON.Encode.string)
    Some(
      [
        ("id", dict->Dict.get("id")->Option.getOrThrow),
        ("meta", meta),
        ("recordedAt", recordedAt),
        ("event", ReventlessCore.Message.combineMessage(eventType, payload)),
      ]
      ->Dict.fromArray
      ->JSON.Encode.object,
    )
  | _ => None
  }
}

let buildJsonState = dict => Some(dict->JSON.Encode.object)

let parseDynamoDbStreamRecord = (buildJson, record: PulumiAws.DynamoDb.Stream.record) => {
  let record = record.dynamodb
  let id = record->Option.flatMap(record => AwsSdk.DynamoDb_Util_Helpers.unmarshall(record.keys.id))

  let newImageJson =
    record
    ->Option.flatMap(dynamodb => dynamodb.newImage)
    ->Option.map(newImage => AwsSdk.DynamoDb_Util_Helpers.unmarshallDict(newImage))
    ->Option.flatMap(buildJson)

  let oldImageJson =
    record
    ->Option.flatMap(dynamodb => dynamodb.oldImage)
    ->Option.map(oldImage => AwsSdk.DynamoDb_Util_Helpers.unmarshallDict(oldImage))
    ->Option.flatMap(buildJson)

  switch (id, newImageJson, oldImageJson) {
  | (Some(id), Some(newImage), Some(oldImage)) => NewAndOldImage(id, newImage, oldImage)
  | (Some(id), Some(newImage), None) => NewImage(id, newImage)
  | (Some(id), None, Some(oldImage)) => OldImage(id, oldImage)
  | _ => Invalid
  }
}

let parseDynamoDbStreamRecordEvent: PulumiAws.DynamoDb.Stream.record => result = record =>
  parseDynamoDbStreamRecord(buildJsonEvent', record)

// let parseDynamoDbStreamRecord = record =>
//   switch record
//   ->PulumiAws.DynamoDb.Stream.asRecord
//   ->parseDynamoDbStreamRecordEvent {
//   | NewImage(_, newImage)
//   | NewAndOldImage(_, newImage, _) =>
//     Some(newImage)
//   | _ =>
//     Console.log(__MODULE__ ++ ".handleChannelEvent: no NewImage included in Stream event !")
//     None
//   }

let parseDynamoDbStreamRecordState: PulumiAws.DynamoDb.Stream.record => result = record =>
  parseDynamoDbStreamRecord(buildJsonState, record)

let findResource = resources =>
  resources->ReventlessCore.Util.AdapterRuntime.findResource(AWS.DynamoDbStream.service)
