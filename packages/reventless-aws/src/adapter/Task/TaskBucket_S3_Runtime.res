let handleBucketEvent = handleEvent => async (event: PulumiAws.S3.Bucket.event, _) => {
  let record = event.records->Array.getUnsafe(0)
  let eventName = record.eventName
  let key = Js.Global.decodeURIComponent(record.s3.object.key)
  let _ = handleEvent(~eventName, ~key)
}
